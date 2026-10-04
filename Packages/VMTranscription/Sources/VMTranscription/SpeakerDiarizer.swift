import AVFoundation
import FluidAudio
import Foundation
import VMCore

/// One stretch of speech attributed to an anonymous speaker cluster.
public struct DiarizedTurn: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    /// Opaque cluster label from the diarizer; only equality matters.
    public let cluster: String

    public init(start: TimeInterval, end: TimeInterval, cluster: String) {
        self.start = start
        self.end = end
        self.cluster = cluster
    }
}

/// Splits the other side of a call (one mixed system-audio stream) into
/// anonymous speakers, entirely on this Mac.
///
/// Wraps FluidAudio's offline pipeline (pyannote community-1: powerset
/// segmentation + VBx clustering on CoreML). The models download once from
/// Hugging Face into FluidAudio's own cache, the same way WhisperKit models do.
/// This is the only type in the app that touches FluidAudio. It is an actor
/// because the underlying manager isn't `Sendable`, and so the work stays off
/// the main actor.
public actor SpeakerDiarizer {
    /// FluidAudio's manager isn't `Sendable`. Like WhisperKitEngine's
    /// `PipelineBox`, this actor is its only user and calls it strictly one
    /// request at a time, so the unchecked box is safe.
    private struct ManagerBox: @unchecked Sendable { let value: OfflineDiarizerManager }
    private var models: OfflineDiarizerModels?

    public init() {}

    /// Download (first time only) and load the diarization models.
    public func prepareModels() async throws {
        if models != nil { return }
        models = try await OfflineDiarizerModels.load()
    }

    /// - Parameters:
    ///   - samples: 16 kHz mono audio.
    ///   - maxSpeakers: upper bound on how many speakers to find (from the
    ///     calendar invite), or `nil` to let the clustering decide.
    /// - Returns: turns sorted by start; empty when there is no speech.
    public func diarize(samples: [Float], maxSpeakers: Int? = nil) async throws -> [DiarizedTurn] {
        try await prepareModels()
        guard let models else { return [] }
        var config = OfflineDiarizerConfig.default
        config.clustering.maxSpeakers = maxSpeakers
        let manager = ManagerBox(value: OfflineDiarizerManager(config: config))
        manager.value.initialize(models: models)
        let result: DiarizationResult
        do {
            result = try await manager.value.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
        return result.segments
            .map { DiarizedTurn(start: TimeInterval($0.startTimeSeconds),
                                end: TimeInterval($0.endTimeSeconds),
                                cluster: $0.speakerId) }
            .sorted { $0.start < $1.start }
    }
}

/// Reads the "other people" side of a saved recording.
public enum StereoAudioLoader {
    public enum LoadError: LocalizedError {
        case notStereo
        case converterUnavailable

        public var errorDescription: String? {
            switch self {
            case .notStereo: "The recording has no separate channel for the other participants."
            case .converterUnavailable: "The recording's audio format couldn't be converted."
            }
        }
    }

    /// The system-audio channel (right channel of `audio.m4a`; the mic is left)
    /// as 16 kHz mono Float32, plus its duration in seconds.
    public static func loadSystemChannel(url: URL) throws -> (samples: [Float], duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount == 2 else { throw LoadError.notStereo }

        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMChunk.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: mono, to: target) else { throw LoadError.converterUnavailable }

        let chunk: AVAudioFrameCount = 48_000
        guard let stereo = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw LoadError.converterUnavailable }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * PCMChunk.sampleRate / format.sampleRate) + 1024)

        while file.framePosition < file.length {
            try file.read(into: stereo, frameCount: chunk)
            if stereo.frameLength == 0 { break }
            guard let channels = stereo.floatChannelData,
                  let right = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: stereo.frameLength) else { break }
            right.frameLength = stereo.frameLength
            right.floatChannelData![0].update(from: channels[1], count: Int(stereo.frameLength))
            out += convert(right, with: converter, to: target)
        }
        return (out, Double(out.count) / PCMChunk.sampleRate)
    }

    /// Streaming conversion: the converter keeps its filter state between
    /// buffers (no reset, `.noDataNow` after each buffer is consumed).
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}
