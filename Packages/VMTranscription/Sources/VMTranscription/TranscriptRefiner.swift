import AVFoundation
import Foundation
import VMCore

/// The post-meeting pass: transcribe both sides of a saved recording again, properly.
///
/// The live transcript is made under pressure — 30-second windows re-decoded every few seconds, on
/// whatever model keeps up in real time. Afterwards there's no hurry: each side of the recording is
/// read in order by a larger model, with each window's text as context for the next, and the result goes
/// through the same cleaning as the live one (noise and hallucination filter, echo removal, duplicate
/// collapsing). It reads `audio.m4a` itself — the raw stereo file — never the echo-reduced copy, which
/// is mono and has the other side removed.
public enum TranscriptRefiner {
    public struct Result: Sendable {
        public let segments: [TranscriptSegment]
        public let audioSeconds: TimeInterval
        public let elapsedSeconds: TimeInterval
        /// Seconds of detected speech on each side, by speaker id — for judging how complete a transcript is.
        public let speechSeconds: [String: Double]
    }

    /// - Parameters:
    ///   - engine: a `WhisperKitEngine` with a model already loaded (use a separate instance from the live
    ///     one, so a recording in progress isn't disturbed).
    ///   - echo: how strictly to remove the other side's voice from the "You" channel. `.offline` by
    ///     default: this pass hears the *raw* microphone (the live echo canceller only ever touched what the
    ///     live transcriber heard), and its two channels are timestamped by separate Whisper runs that drift
    ///     apart by seconds, so the text filter has to reach further than it does live. `.conservative` when
    ///     the recording was made on headphones.
    ///   - vocabulary: names and terms to respell where the model is slightly off (see `VocabularyCorrector`).
    ///   - maxSeconds: only the first part of the recording (for evaluation).
    ///   - progress: fraction done, 0…1; return `false` to stop (throws `CancellationError`).
    public static func refine(
        audioURL: URL,
        engine: WhisperKitEngine,
        options: TranscriptionOptions,
        echo: EchoDedup.Config = .offline,
        vocabulary: [String] = [],
        maxSeconds: Double? = nil,
        progress: @escaping @Sendable (Double) -> Bool
    ) async throws -> Result {
        let started = Date()
        var audioSeconds: TimeInterval = 0
        var all: [TranscriptSegment] = []
        var speechSeconds: [String: Double] = [:]

        // Opened once for both sides: "Save & file" can rename the meeting's folder while the first side is
        // still being transcribed, and a second open by path would then fail.
        let file = try AVAudioFile(forReading: audioURL)

        // One side at a time: each is up to ~230 MB an hour, so don't hold both.
        let sides: [(index: Int, channel: AudioChannel, speaker: Speaker)] = [
            (StereoAudio.micChannel, .mic, Speaker.you),
            (StereoAudio.systemChannel, .system, Speaker.others),
        ]
        for (position, side) in sides.enumerated() {
            let samples = try StereoAudio.loadChannel(side.index, from: file, maxSeconds: maxSeconds)
            audioSeconds = max(audioSeconds, Double(samples.count) / PCMChunk.sampleRate)
            guard !samples.isEmpty, hasSignal(samples) else { continue }
            speechSeconds[side.speaker.id] = SpeechActivity.analyze(samples).speechSeconds

            let low = Double(position) / Double(sides.count)
            let span = 1.0 / Double(sides.count)
            let segments = try await engine.transcribeSamples(
                samples,
                channel: side.channel,
                speakerId: side.speaker.id,
                options: options,
                progress: { fraction in progress(low + fraction * span) }
            )
            all += segments
        }
        _ = progress(1)

        // The live pass's own cleaning: drops noise and hallucinations, removes the other side's voice
        // from the microphone channel, merges back-to-back duplicates.
        let merger = SegmentMerger(echoConfig: echo)
        merger.setVocabulary(VocabularyCorrector(terms: vocabulary))
        for segment in all.sorted(by: { $0.start < $1.start }) {
            merger.ingest(segment)
        }
        return Result(
            segments: merger.finalSnapshot(),
            audioSeconds: audioSeconds,
            elapsedSeconds: Date().timeIntervalSince(started),
            speechSeconds: speechSeconds
        )
    }

    /// A channel that's digital silence (a muted mic, no system audio) has nothing to transcribe, and
    /// Whisper invents text for silence.
    private static func hasSignal(_ samples: [Float]) -> Bool {
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            if peak > 0.002 { return true }
        }
        return false
    }
}
