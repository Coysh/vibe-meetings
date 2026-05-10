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
/// IMPLEMENTATION NOTE: The Core Audio Tap APIs expose a fair amount of low-level CoreAudio
/// machinery that is best validated against a real macOS device. The skeleton below sets up
/// the tap, aggregate device, and IOProc; the IOProc body that copies bytes out of
/// `AudioBufferList` and into `AVAudioPCMBuffer` is the most likely point that needs
/// per-machine fine-tuning. See README "Phase 4 — System audio" for what to verify.
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

    public init() {
        var pCont: AsyncStream<PCMChunk>.Continuation!
        self.pcm = AsyncStream { pCont = $0 }
        self.pcmContinuation = pCont

        var bCont: AsyncStream<SendableAudioBuffer>.Continuation!
        self.buffers = AsyncStream { bCont = $0 }
        self.bufferContinuation = bCont
    }

    public func start(epoch: TimeInterval) throws {
        startEpoch = epoch

        // 1. Build a tap description targeting the default output device's audio.
        let desc = CATapDescription(stereoMixdownOfProcesses: [])
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.isExclusive = false

        var newTapID: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard status == noErr else {
            throw AudioCaptureError.systemTapFailed("AudioHardwareCreateProcessTap failed: OSStatus \(status)")
        }
        self.tapID = newTapID

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
            throw AudioCaptureError.systemTapFailed("AudioHardwareCreateAggregateDevice failed: OSStatus \(status)")
        }
        self.aggregateID = newAggID

        self.tapFormat = try Self.streamFormat(for: newAggID)

        // 3. Install IOProc.
        let cb: AudioDeviceIOProc = { _, inNow, inInputData, inInputTime, _, _, clientData in
            guard let clientData else { return noErr }
            let me = Unmanaged<SystemAudioCapturer>.fromOpaque(clientData).takeUnretainedValue()
            me.handle(bufferList: inInputData, hostTime: inNow.pointee.mHostTime, inputTime: inInputTime.pointee)
            return noErr
        }

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, newAggID, nil) { [weak self] inNow, inInputData, inInputTime, _, _ in
            self?.handle(bufferList: inInputData, hostTime: inNow.pointee.mHostTime, inputTime: inInputTime.pointee)
        }
        guard status == noErr, let procID else {
            _ = cb // silence unused warning for the explicit-cb fallback path
            throw AudioCaptureError.systemTapFailed("AudioDeviceCreateIOProcID failed: OSStatus \(status)")
        }
        self.ioProcID = procID

        status = AudioDeviceStart(newAggID, procID)
        guard status == noErr else {
            throw AudioCaptureError.systemTapFailed("AudioDeviceStart failed: OSStatus \(status)")
        }
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

    private func handle(bufferList: UnsafePointer<AudioBufferList>, hostTime: UInt64, inputTime: AudioTimeStamp) {
        guard let format = tapFormat else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let firstBuf = abl.first else { return }

        let frames = AVAudioFrameCount(firstBuf.mDataByteSize / (format.streamDescription.pointee.mBytesPerFrame))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames

        // Copy each channel into the destination buffer.
        for (i, b) in abl.enumerated() {
            guard i < Int(format.channelCount), let src = b.mData else { continue }
            if let dst = pcm.floatChannelData?[i] {
                memcpy(dst, src, Int(b.mDataByteSize))
            }
        }

        bufferContinuation.yield(SendableAudioBuffer(pcm))
        let samples = (try? converter.convert(pcm)) ?? []
        if !samples.isEmpty {
            let ts = MicrophoneCapturer.hostTime(hostTime) - startEpoch
            pcmContinuation.yield(PCMChunk(samples: samples, timestamp: ts))
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
