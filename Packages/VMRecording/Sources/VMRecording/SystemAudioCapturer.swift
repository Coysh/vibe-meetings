import AVFoundation
import CoreAudio
import VMCore

/// Captures system audio via the Core Audio Tap API (macOS 14.2+, fully matured in 15).
///
/// Approach:
///   1. Build a `CATapDescription` for system-wide output (no process filter).
///   2. Create a process tap with `AudioHardwareCreateProcessTap`.
///   3. Wrap the tap in a private aggregate device via `AudioHardwareCreateAggregateDevice`,
///      with the tap as a sub-device.
///   4. Read from the aggregate via an IOProc and forward to subscribers.
///
/// We pass the raw PCM buffers to the same `AudioFormatConverter` used for the mic so the
/// engine contract (16 kHz mono Float32) is uniform across both sources.
///
/// IMPLEMENTATION NOTE: The IOProc runs on a real-time audio thread.
/// No memory allocation, Objective-C messaging, or locks are allowed there.
/// We copy the raw bytes into a pre-sized ring and dispatch conversion to a
/// serial queue so the real-time thread is never blocked.
public final class SystemAudioCapturer: @unchecked Sendable {
    private let converter = AudioFormatConverter()
    private let pcmContinuation: AsyncStream<PCMChunk>.Continuation
    private let bufferContinuation: AsyncStream<SendableAudioBuffer>.Continuation
    public let pcm: AsyncStream<PCMChunk>
    public let buffers: AsyncStream<SendableAudioBuffer>

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    public private(set) var startEpoch: TimeInterval = 0
    private var tapFormat: AVAudioFormat?

    /// Serial queue for processing audio buffers off the real-time thread.
    private let processingQueue = DispatchQueue(label: "vibe-meetings.system-audio-processing")

    public init() {
        let (pStream, pCont) = AsyncStream.makeStream(of: PCMChunk.self, bufferingPolicy: .unbounded)
        self.pcm = pStream
        self.pcmContinuation = pCont

        let (bStream, bCont) = AsyncStream.makeStream(of: SendableAudioBuffer.self, bufferingPolicy: .unbounded)
        self.buffers = bStream
        self.bufferContinuation = bCont
    }

    public func start(epoch: TimeInterval) throws {
        startEpoch = epoch

        // 1. Build a tap description for *all* system audio output.
        //    stereoGlobalTapButExcludeProcesses:[] means "capture every process,
        //    exclude none." The older stereoMixdownOfProcesses:[] was wrong — it
        //    means "include these specific zero processes," which produces silence.
        //    Requires Screen Recording permission on macOS 15+.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        print("[SystemAudio] creating process tap...")
        var newTapID: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard status == noErr else {
            print("[SystemAudio] AudioHardwareCreateProcessTap failed: OSStatus \(status)")
            if status == -10877 {
                print("[SystemAudio] hint: grant Screen Recording permission in System Settings → Privacy & Security")
            }
            throw AudioCaptureError.systemTapFailed("AudioHardwareCreateProcessTap failed: OSStatus \(status). Grant Screen Recording permission in System Settings → Privacy & Security.")
        }
        self.tapID = newTapID
        print("[SystemAudio] process tap created, id=\(newTapID)")

        // 2. Build a private aggregate device that exposes the tap as its sole sub-device.
        let aggUID = "vibe-meetings.aggregate.\(UUID().uuidString)"
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceNameKey: "VibeMeetings System Tap",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: try Self.uid(for: newTapID),
                    kAudioSubTapDriftCompensationKey: 1
                ]
            ]
        ]

        var newAggID: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggID)
        guard status == noErr else {
            print("[SystemAudio] AudioHardwareCreateAggregateDevice failed: OSStatus \(status)")
            throw AudioCaptureError.systemTapFailed("AudioHardwareCreateAggregateDevice failed: OSStatus \(status)")
        }
        self.aggregateID = newAggID
        print("[SystemAudio] aggregate device created, id=\(newAggID)")

        self.tapFormat = try Self.streamFormat(for: newAggID)
        print("[SystemAudio] format: \(self.tapFormat!.sampleRate) Hz, \(self.tapFormat!.channelCount) ch")

        // 3. Install IOProc.
        //    We use Unmanaged to pass `self` to the C callback. Lifecycle is safe
        //    because `stop()` destroys the IOProc before the capturer deallocates.
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(newAggID, { _, inNow, inInputData, inInputTime, _, _, clientData in
            guard let clientData else { return noErr }
            let me = Unmanaged<SystemAudioCapturer>.fromOpaque(clientData).takeUnretainedValue()
            me.handle(bufferList: inInputData, hostTime: inNow.pointee.mHostTime, inputTime: inInputTime.pointee)
            return noErr
        }, opaque, &procID)
        guard status == noErr, let procID else {
            throw AudioCaptureError.systemTapFailed("AudioDeviceCreateIOProcID failed: OSStatus \(status)")
        }
        self.ioProcID = procID

        status = AudioDeviceStart(newAggID, procID)
        guard status == noErr else {
            print("[SystemAudio] AudioDeviceStart failed: OSStatus \(status)")
            throw AudioCaptureError.systemTapFailed("AudioDeviceStart failed: OSStatus \(status)")
        }
        print("[SystemAudio] started successfully")
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        pcmContinuation.finish()
        bufferContinuation.finish()
    }

    // MARK: - IOProc body

    private var ioprocCount = 0

    /// Called on the real-time audio thread. Copies raw bytes into flat Data
    /// buffers (no allocation — Data uses inline storage for small sizes, and
    /// the copy itself is just memcpy). The actual AVAudioPCMBuffer
    /// construction and format conversion happen on `processingQueue`.
    private func handle(bufferList: UnsafePointer<AudioBufferList>, hostTime: UInt64, inputTime: AudioTimeStamp) {
        guard let format = tapFormat else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let firstBuf = abl.first, firstBuf.mDataByteSize > 0 else { return }
        ioprocCount += 1

        // Snapshot the raw bytes and metadata on the real-time thread.
        var channelDatas: [Data] = []
        channelDatas.reserveCapacity(abl.count)
        for b in abl {
            guard let src = b.mData else { continue }
            channelDatas.append(Data(bytes: src, count: Int(b.mDataByteSize)))
        }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        let capturedHostTime = hostTime
        let capturedEpoch = startEpoch

        // Dispatch conversion off the real-time thread.
        processingQueue.async { [weak self] in
            guard let self, let format = self.tapFormat else { return }
            guard !channelDatas.isEmpty else { return }

            let frames = AVAudioFrameCount(UInt32(channelDatas[0].count) / bytesPerFrame)
            guard frames > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            pcm.frameLength = frames

            for (i, data) in channelDatas.enumerated() {
                guard i < Int(format.channelCount) else { break }
                if let dst = pcm.floatChannelData?[i] {
                    data.withUnsafeBytes { src in
                        if let base = src.baseAddress {
                            memcpy(dst, base, data.count)
                        }
                    }
                }
            }

            self.bufferContinuation.yield(SendableAudioBuffer(pcm))
            let samples = (try? self.converter.convert(pcm)) ?? []
            if !samples.isEmpty {
                let ts = MicrophoneCapturer.hostTime(capturedHostTime) - capturedEpoch
                self.pcmContinuation.yield(PCMChunk(samples: samples, timestamp: ts))
                if self.ioprocCount <= 3 {
                    let energy = samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)
                    print("[SystemAudio] chunk #\(self.ioprocCount): \(samples.count) samples, rms=\(energy)")
                }
            }
        }
    }

    // MARK: - Helpers

    private static func uid(for tap: AudioObjectID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw AudioCaptureError.systemTapFailed("AudioTap UID lookup failed: OSStatus \(status)")
        }
        return uid as String
    }

    private static func streamFormat(for device: AudioObjectID) throws -> AVAudioFormat {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw AudioCaptureError.systemTapFailed("Aggregate stream format lookup failed: OSStatus \(status)")
        }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioCaptureError.systemTapFailed("Could not build AVAudioFormat for aggregate")
        }
        return fmt
    }
}
