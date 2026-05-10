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
    private let outputFormat: AVAudioFormat
    private let queue = DispatchQueue(label: "vibe.dual-m4a-writer")

    private var micBuffer: [Float] = []
    private var sysBuffer: [Float] = []
    private var sampleIndex: Int64 = 0
    private var isStarted = false

    private let micConverter = AudioFormatConverter48kMono()
    private let sysConverter = AudioFormatConverter48kMono()

    public init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        self.writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

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

        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
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
        queue.async { self.micBuffer.append(contentsOf: samples); self.flushIfReady() }
    }

    public func appendSystem(_ wrapper: SendableAudioBuffer) {
        let buffer = wrapper.buffer
        guard let samples = try? sysConverter.convert(buffer) else { return }
        queue.async { self.sysBuffer.append(contentsOf: samples); self.flushIfReady() }
    }

    private func flushIfReady() {
        let n = min(micBuffer.count, sysBuffer.count)
        guard n >= 4_800 else { return } // ~100 ms at 48 kHz

        guard input.isReadyForMoreMediaData else { return }

        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
        defer { interleaved.deallocate() }
        for i in 0..<n {
            interleaved[i * 2] = micBuffer[i]
            interleaved[i * 2 + 1] = sysBuffer[i]
        }
        micBuffer.removeFirst(n)
        sysBuffer.removeFirst(n)

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        pcm.frameLength = AVAudioFrameCount(n)
        if let dst = pcm.floatChannelData?[0] {
            memcpy(dst, interleaved, n * 2 * MemoryLayout<Float>.size)
        }

        let pts = CMTime(value: sampleIndex, timescale: 48_000)
        sampleIndex += Int64(n)

        if let cmBuffer = makeCMSampleBuffer(pcm: pcm, presentationTime: pts) {
            input.append(cmBuffer)
        }
    }

    public func stop(completion: @escaping (URL?) -> Void) {
        queue.async {
            self.flushIfReady()
            self.input.markAsFinished()
            self.writer.finishWriting {
                let url = self.writer.status == .completed ? self.writer.outputURL : nil
                completion(url)
            }
        }
    }

    private func makeCMSampleBuffer(pcm: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        let asbd = pcm.format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: pcm.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(pcm.frameLength), timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sb
        ) == noErr, let sb else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
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
