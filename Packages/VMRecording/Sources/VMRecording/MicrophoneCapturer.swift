import AVFoundation
import VMCore

/// Captures mic audio with `AVAudioEngine`, emits `PCMChunk`s and raw `AVAudioPCMBuffer`s.
public final class MicrophoneCapturer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = AudioFormatConverter()
    private let pcmContinuation: AsyncStream<PCMChunk>.Continuation
    private let bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    public let pcm: AsyncStream<PCMChunk>
    public let buffers: AsyncStream<AVAudioPCMBuffer>
    public private(set) var startEpoch: TimeInterval = 0

    public init() {
        var pCont: AsyncStream<PCMChunk>.Continuation!
        self.pcm = AsyncStream { pCont = $0 }
        self.pcmContinuation = pCont

        var bCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.buffers = AsyncStream { bCont = $0 }
        self.bufferContinuation = bCont
    }

    public func start(epoch: TimeInterval) throws {
        startEpoch = epoch
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw AudioCaptureError.audioEngineFailed("Input node reports zero sample rate; mic permission?")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.bufferContinuation.yield(buffer.copy() as! AVAudioPCMBuffer)
            let samples = (try? self.converter.convert(buffer)) ?? []
            if !samples.isEmpty {
                let ts = Self.hostTime(when.hostTime) - self.startEpoch
                self.pcmContinuation.yield(PCMChunk(samples: samples, timestamp: ts))
            }
        }

        try engine.start()
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
