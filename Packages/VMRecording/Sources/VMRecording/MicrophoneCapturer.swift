import AVFoundation
import CoreAudio
import VMCore

/// Captures mic audio with `AVAudioEngine`, emits `PCMChunk`s and raw audio
/// buffers (wrapped in `SendableAudioBuffer` so they can travel through the
/// `AsyncStream` under Swift 6 strict concurrency).
public final class MicrophoneCapturer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = AudioFormatConverter()
    private let pcmContinuation: AsyncStream<PCMChunk>.Continuation
    private let bufferContinuation: AsyncStream<SendableAudioBuffer>.Continuation
    public let pcm: AsyncStream<PCMChunk>
    public let buffers: AsyncStream<SendableAudioBuffer>
    public private(set) var startEpoch: TimeInterval = 0

    public init() {
        let (pStream, pCont) = AsyncStream.makeStream(of: PCMChunk.self, bufferingPolicy: .unbounded)
        self.pcm = pStream
        self.pcmContinuation = pCont

        let (bStream, bCont) = AsyncStream.makeStream(of: SendableAudioBuffer.self, bufferingPolicy: .unbounded)
        self.buffers = bStream
        self.bufferContinuation = bCont
    }

    deinit {
        print("[MicCapturer] DEINIT — MicrophoneCapturer is being deallocated!")
    }

    /// Start capturing from a specific device, or the system default if `nil`.
    public func start(epoch: TimeInterval, deviceID: AudioDeviceID? = nil) throws {
        startEpoch = epoch

        let input = engine.inputNode

        // If the caller requested a specific device, point the engine's
        // input node at it before querying format or installing a tap.
        if let deviceID {
            var devID = deviceID
            let audioUnit = input.audioUnit!
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                print("[MicCapturer] set input device id=\(deviceID)")
            } else {
                print("[MicCapturer] failed to set device \(deviceID): OSStatus \(status)")
            }
        } else {
            print("[MicCapturer] using system default input device")
        }

        let format = input.inputFormat(forBus: 0)
        print("[MicCapturer] format: \(format.sampleRate) Hz, \(format.channelCount) ch")
        guard format.sampleRate > 0 else {
            throw AudioCaptureError.audioEngineFailed("Input node reports zero sample rate; mic permission?")
        }

        var tapCount = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            tapCount += 1
            let copy = buffer.copy() as! AVAudioPCMBuffer
            self.bufferContinuation.yield(SendableAudioBuffer(copy))
            do {
                let samples = try self.converter.convert(buffer)
                if !samples.isEmpty {
                    let ts = Self.hostTime(when.hostTime) - self.startEpoch
                    let result = self.pcmContinuation.yield(PCMChunk(samples: samples, timestamp: ts))

                    if tapCount <= 3 || tapCount % 100 == 0 {
                        let energy = samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)
                        print("[MicCapturer] tap #\(tapCount): \(samples.count) samples, rms=\(energy), yield=\(result)")
                    }
                    // Detect if the continuation has been prematurely terminated.
                    if case .terminated = result {
                        print("[MicCapturer] ⚠️ pcmContinuation.yield returned .terminated at tap #\(tapCount)!")
                    }
                } else if tapCount <= 3 {
                    print("[MicCapturer] tap #\(tapCount): converter returned empty samples")
                }
            } catch {
                print("[MicCapturer] conversion error at tap #\(tapCount): \(error)")
            }
        }

        try engine.start()
        print("[MicCapturer] engine started")
    }

    /// Switch the capture device mid-recording without tearing down the
    /// async streams. Removes the existing tap, reconfigures the input node,
    /// re-installs the tap, and restarts the engine.
    public func switchDevice(to deviceID: AudioDeviceID?) throws {
        guard engine.isRunning else { return }

        // 1. Tear down current capture.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let input = engine.inputNode

        // 2. Reconfigure the device.
        if let deviceID {
            var devID = deviceID
            let audioUnit = input.audioUnit!
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                print("[MicCapturer] switched to device id=\(deviceID)")
            } else {
                print("[MicCapturer] failed to switch to device \(deviceID): OSStatus \(status)")
            }
        } else {
            print("[MicCapturer] switched to system default input device")
        }

        // 3. Re-install tap with the new device's format.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw AudioCaptureError.audioEngineFailed("New input device reports zero sample rate")
        }

        var tapCount = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            tapCount += 1
            let copy = buffer.copy() as! AVAudioPCMBuffer
            self.bufferContinuation.yield(SendableAudioBuffer(copy))
            do {
                let samples = try self.converter.convert(buffer)
                if !samples.isEmpty {
                    let ts = Self.hostTime(when.hostTime) - self.startEpoch
                    self.pcmContinuation.yield(PCMChunk(samples: samples, timestamp: ts))
                }
            } catch {
                if tapCount <= 3 {
                    print("[MicCapturer] conversion error after switch at tap #\(tapCount): \(error)")
                }
            }
        }

        try engine.start()
        print("[MicCapturer] engine restarted after device switch")
    }

    public func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        pcmContinuation.finish()
        bufferContinuation.finish()
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func hostTime(_ ht: UInt64) -> TimeInterval {
        let nanos = Double(ht) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1e9
    }

    public static func nowHostSeconds() -> TimeInterval {
        hostTime(mach_absolute_time())
    }
}
