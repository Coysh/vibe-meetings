import AVFoundation
import VMCore

/// Writes mic on L and system on R into a stereo AAC m4a file.
///
/// The two input streams arrive at different sample rates and clock rates, so we resample
/// each to a common 48 kHz mono float buffer, then interleave them into a stereo frame
/// before pushing to `AVAssetWriterInput`. Frame alignment is best-effort: we drift-correct
/// by trimming or zero-padding the shorter side at flush time. For meeting use this is
/// acceptable; if you need sample-accurate sync, swap the writer for one driven by a single
/// shared clock (an AVAudioEngine mixer with two inputs is the natural choice).
public final class DualChannelM4AWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "vibe.dual-m4a-writer")

    private var micBuffer: [Float] = []
    private var sysBuffer: [Float] = []
    private var sampleIndex: Int64 = 0
    private var isStarted = false
    private var micHasData = false
    private var sysHasData = false
    private var flushCount = 0

    private let micConverter = AudioFormatConverter48kMono()
    private let sysConverter = AudioFormatConverter48kMono()

    /// Crash-safe raw WAV sidecar. Written on the same serial `queue` as the
    /// m4a, deleted on a clean stop. Survives a crash for recovery on relaunch.
    private let wavWriter: CrashSafeWAVWriter?
    private let wavURL: URL?

    public init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        self.writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

        // Sibling crash-safe WAV: same folder, fixed filename. Best-effort —
        // if it can't be opened we still record to the m4a as before.
        let wavSibling = url.deletingLastPathComponent().appendingPathComponent("audio-partial.wav")
        self.wavURL = wavSibling
        self.wavWriter = try? CrashSafeWAVWriter(url: wavSibling)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        self.input = inp
        writer.add(inp)

    }

    public func start() {
        queue.sync {
            guard !isStarted else { return }
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            isStarted = true
        }
    }

    public func appendMic(_ wrapper: SendableAudioBuffer) {
        let buffer = wrapper.buffer
        guard let samples = try? micConverter.convert(buffer) else { return }
        queue.async {
            self.micHasData = true
            self.micBuffer.append(contentsOf: samples)
            self.flushIfReady()
        }
    }

    public func appendSystem(_ wrapper: SendableAudioBuffer) {
        let buffer = wrapper.buffer
        guard let samples = try? sysConverter.convert(buffer) else { return }
        queue.async {
            self.sysHasData = true
            self.sysBuffer.append(contentsOf: samples)
            self.flushIfReady()
        }
    }

    private func flushIfReady() {
        // Determine how many frames we can write. If one channel has no data
        // at all (system tap failed, or mic is the only source), pad it with
        // silence so the writer isn't blocked indefinitely.
        let threshold = 4_800 // ~100 ms at 48 kHz
        let micN = micBuffer.count
        let sysN = sysBuffer.count

        let n: Int
        if micHasData && sysHasData {
            n = min(micN, sysN)
        } else if micHasData {
            n = micN
        } else if sysHasData {
            n = sysN
        } else {
            return
        }
        guard n >= threshold else { return }
        guard input.isReadyForMoreMediaData else { return }

        writeFrames(n, micN: micN, sysN: sysN)

        flushCount += 1
        if flushCount <= 3 {
            print("[M4AWriter] flush #\(flushCount): \(n) frames, mic=\(micN)/sys=\(sysN)")
        }
    }

    /// Interleave `n` frames from the mic and sys buffers into an Int16 stereo
    /// CMSampleBuffer and append it to the asset writer input.
    private func writeFrames(_ n: Int, micN: Int, sysN: Int) {
        // Build interleaved Int16 stereo: [L0, R0, L1, R1, …]
        let sampleCount = n * 2
        var int16 = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<n {
            let micSample = i < micN ? micBuffer[i] : Float(0)
            let sysSample = i < sysN ? sysBuffer[i] : Float(0)
            int16[i * 2]     = floatToInt16(micSample)
            int16[i * 2 + 1] = floatToInt16(sysSample)
        }
        // Durably append these samples to the crash-safe WAV sidecar first, so a
        // crash between here and finishWriting still leaves recoverable audio.
        wavWriter?.append(int16)
        if micN >= n { micBuffer.removeFirst(n) } else { micBuffer.removeAll() }
        if sysN >= n { sysBuffer.removeFirst(n) } else { sysBuffer.removeAll() }

        let pts = CMTime(value: sampleIndex, timescale: 48_000)
        sampleIndex += Int64(n)

        if let sb = makeCMSampleBuffer(int16: &int16, frameCount: n, presentationTime: pts) {
            let ok = input.append(sb)
            if !ok && flushCount < 3 {
                print("[M4AWriter] append failed, writer status=\(writer.status.rawValue), error=\(String(describing: writer.error))")
            }
        }
    }

    public func stop(completion: @escaping (URL?) -> Void) {
        queue.async {
            // Flush any remaining samples with a lowered threshold.
            let n = max(self.micBuffer.count, self.sysBuffer.count)
            if n > 0 {
                let micN = self.micBuffer.count
                let sysN = self.sysBuffer.count
                self.writeFrames(n, micN: micN, sysN: sysN)
            }
            print("[M4AWriter] stop: \(self.flushCount) flushes, \(self.sampleIndex) total samples, writer status=\(self.writer.status.rawValue)")

            // `markAsFinished()` and `finishWriting` may only be called while the
            // writer is actively `.writing`. If the meeting ended before any audio
            // was captured (so `start()`/`startWriting()` never ran, leaving status
            // `.unknown`), or the writer already failed/completed, calling them throws
            // an uncatchable NSInternalInconsistencyException that aborts the process.
            guard self.isStarted, self.writer.status == .writing else {
                print("[M4AWriter] stop: writer not in .writing state (status=\(self.writer.status.rawValue)), skipping finishWriting")
                // The m4a is unusable, but the WAV sidecar holds everything we
                // captured — finalize it so it's playable and keep it around.
                self.finalizeWAVAsFallback()
                completion(nil)
                return
            }

            self.input.markAsFinished()
            self.writer.finishWriting {
                self.queue.async {
                    let completed = self.writer.status == .completed
                    let url = completed ? self.writer.outputURL : nil
                    if completed {
                        // m4a is authoritative — drop the sidecar.
                        self.wavWriter?.close()
                        if let wavURL = self.wavURL { try? FileManager.default.removeItem(at: wavURL) }
                    } else {
                        print("[M4AWriter] finishWriting failed: status=\(self.writer.status.rawValue), error=\(String(describing: self.writer.error))")
                        self.finalizeWAVAsFallback()
                    }
                    completion(url)
                }
            }
        }
    }

    /// Patch the WAV header so the captured audio is playable, leaving the file
    /// in place as the recording of record when the m4a couldn't be finalized.
    private func finalizeWAVAsFallback() {
        wavWriter?.finalize()
    }

    /// Convert Float32 [-1, 1] to Int16 with clamping.
    private func floatToInt16(_ f: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, f))
        return Int16(clamped * Float(Int16.max))
    }

    /// Build a CMSampleBuffer from interleaved Int16 stereo data.
    private func makeCMSampleBuffer(int16: inout [Int16], frameCount: Int, presentationTime: CMTime) -> CMSampleBuffer? {
        // ASBD for interleaved Int16 stereo at 48 kHz.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,   // 2 channels × 2 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        // Provide a stereo channel layout so the AAC encoder (and later AVPlayer)
        // correctly maps L/R channels.
        var layout = AudioChannelLayout(
            mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription(
                mChannelLabel: kAudioChannelLabel_Left,
                mChannelFlags: [],
                mCoordinates: (0, 0, 0)
            )
        )
        let layoutSize = MemoryLayout<AudioChannelLayout>.size

        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: layoutSize,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        let byteCount = frameCount * 4  // 2 channels × 2 bytes per sample
        var blockBuffer: CMBlockBuffer?
        // Allocate a block buffer and copy Int16 data into it.
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let bb = blockBuffer else { return nil }

        // Copy actual data into the block buffer.
        guard int16.withUnsafeBytes({ rawBuf -> OSStatus in
            CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }) == noErr else { return nil }

        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sb
        ) == noErr else { return nil }

        return sb
    }
}

/// Convenience converter to 48 kHz mono Float32 — different output format than the engine
/// converter (which targets 16 kHz).
final class AudioFormatConverter48kMono {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        if inputFormat != buffer.format || converter == nil {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return [] }
        converter.reset()

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return [] }

        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
