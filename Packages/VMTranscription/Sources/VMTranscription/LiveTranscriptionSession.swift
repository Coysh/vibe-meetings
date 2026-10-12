import Foundation
import VMCore

/// One decoded stretch of speech, in seconds from the start of the audio that was decoded.
public struct DecodedSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var confidence: Float?

    public init(start: Double, end: Double, text: String, confidence: Float? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

/// Live transcription of one side of a call, in the way that loses the least.
///
/// The old approach decoded the last 30 seconds every 5 seconds and let each new decode replace the
/// overlapping older text. But a window's first words are cut mid-sentence, so the newest decode of a
/// stretch of speech was often its *worst* one — and replacing the older, better text with it dropped
/// words. Windows that were mostly silence made things worse: Whisper writes "[silence]" and skips the
/// speech.
///
/// This works the other way round:
/// - **Commit.** Text that has settled (it has newer speech after it, or silence) is final: it's emitted
///   once, as a normal segment, and never changed.
/// - **Advance.** The next decode starts where the committed text ended — a sentence boundary — not
///   mid-word, and is given the text just committed as context so names and spelling stay consistent.
/// - **Tail.** Whatever isn't settled yet is emitted as one in-progress segment with a stable id, rewritten
///   in place on every decode, so the live view shows it as it firms up.
/// - **Speech only.** Silence is never sent to the model; each decode starts at the first word.
public actor LiveTranscriptionSession {
    public struct Configuration: Sendable {
        /// How much new audio to wait for between decodes.
        public var hopSeconds = 5.0
        /// The most audio to decode at once (Whisper's own window).
        public var maxSliceSeconds = 30.0
        /// Segments at the end of a decode that are held back as in-progress. Their right-hand context
        /// is missing, so they may still change.
        public var unsettledSegments = 2
        /// Silence after speech that means the speaker has finished, so everything can be committed.
        public var flushSilenceSeconds = 1.2
        /// Audio kept before the first word, so its start isn't clipped.
        public var leadInSeconds = 0.4
        /// If decoding falls this far behind real time, skip ahead rather than fall further behind.
        public var maxLagSeconds = 90.0
        /// How much of the committed text is given back to the model as context.
        public var contextCharacters = 0

        public init() {}
    }

    public typealias Decoder = @Sendable (_ samples: [Float], _ prompt: String?) async throws -> [DecodedSegment]

    private let channel: AudioChannel
    private let speakerId: String
    private let vocabulary: String?
    private let config: Configuration
    private let decoder: Decoder
    private let sampleRate = PCMChunk.sampleRate

    /// Audio from `bufferStart` (seconds on the capture clock) onward.
    private var samples: [Float] = []
    private var bufferStart: Double = 0
    private var hasStarted = false
    /// Everything before this is final. The next decode starts here.
    private var committedEnd: Double = 0
    private var decodedThrough: Double = 0
    private var committedText = ""
    private let tailID = UUID()
    private var hasTail = false
    /// What the in-progress segment is made of, so that it can be settled if the audio ends.
    private var tailSegments: [DecodedSegment] = []
    /// The room's noise level as far as we've heard: drops straight to anything quieter, creeps up slowly.
    private var noiseFloor: Float?

    public init(
        channel: AudioChannel,
        speakerId: String,
        vocabulary: String? = nil,
        configuration: Configuration = .init(),
        decoder: @escaping Decoder
    ) {
        self.channel = channel
        self.speakerId = speakerId
        self.vocabulary = vocabulary
        self.config = configuration
        self.decoder = decoder
    }

    private var bufferEnd: Double { bufferStart + Double(samples.count) / sampleRate }

    // MARK: - Feeding audio

    /// Add audio. Returns what changed: segments that just became final, then the rewritten in-progress
    /// segment (an empty one if there's nothing in progress any more). Empty when it's not time to decode.
    public func ingest(_ chunk: PCMChunk) async throws -> [TranscriptSegment] {
        if !hasStarted {
            hasStarted = true
            bufferStart = chunk.timestamp
            committedEnd = chunk.timestamp
            decodedThrough = chunk.timestamp
        } else if chunk.timestamp - bufferEnd > 0.5 {
            let gap = chunk.timestamp - bufferEnd
            if gap > config.maxSliceSeconds {
                // A long pause: start afresh from here rather than keep the timeline behind with silence.
                samples.removeAll(keepingCapacity: true)
                bufferStart = chunk.timestamp
                committedEnd = chunk.timestamp
                decodedThrough = chunk.timestamp
            } else {
                // A short dropout: keep the timeline honest with silence.
                samples.append(contentsOf: [Float](repeating: 0, count: Int(gap * sampleRate)))
            }
        }
        samples.append(contentsOf: chunk.samples)

        guard bufferEnd - decodedThrough >= config.hopSeconds else { return [] }
        return try await decodeAvailable(final: false)
    }

    /// Call when the audio ends: decodes what's left and commits everything.
    public func finish() async throws -> [TranscriptSegment] {
        guard hasStarted else { return [] }
        guard bufferEnd - committedEnd > 0.3 else {
            // Next to no audio left to decode, but whatever was in progress still stands: settle it.
            let settled = tailSegments.map { makeSegment($0, partial: false, id: UUID()) }
            return settled + clearTail()
        }
        return try await decodeAvailable(final: true)
    }

    // MARK: - Decoding

    private func decodeAvailable(final: Bool) async throws -> [TranscriptSegment] {
        var updates: [TranscriptSegment] = []

        // Never fall unboundedly behind: if the model can't keep up, jump to the most recent audio.
        if bufferEnd - committedEnd > config.maxLagSeconds {
            committedEnd = bufferEnd - config.maxSliceSeconds
            updates += clearTail()
        }

        // More than one slice waiting means we're catching up: go round again straight away.
        var rounds = 0
        repeat {
            updates += try await decodeOnce(final: final)
            rounds += 1
        } while bufferEnd - committedEnd > config.maxSliceSeconds && rounds < 8

        trimBuffer()
        return updates
    }

    private func decodeOnce(final: Bool) async throws -> [TranscriptSegment] {
        let sliceStart = max(committedEnd, bufferStart)
        let sliceEnd = min(bufferEnd, sliceStart + config.maxSliceSeconds)
        let isCatchingUp = sliceEnd < bufferEnd
        decodedThrough = sliceEnd

        let from = Int((sliceStart - bufferStart) * sampleRate)
        let to = min(samples.count, Int((sliceEnd - bufferStart) * sampleRate))
        guard to > from else { return [] }
        let slice = Array(samples[from..<to])

        let activity = SpeechActivity.analyze(slice, noiseFloor: noiseFloor)
        if let measured = activity.measuredFloor {
            noiseFloor = min(measured, (noiseFloor ?? measured) + 1)
        }
        guard let firstSpeech = activity.firstSpeech, let lastSpeech = activity.lastSpeech else {
            // Nothing but silence: don't ask the model (it would invent something), just move on, keeping
            // a moment of lead-in for whatever comes next.
            committedEnd = max(committedEnd, sliceEnd - config.leadInSeconds)
            return clearTail()
        }

        let startInSlice = max(0, firstSpeech - config.leadInSeconds)
        let speech = SpeechActivity.normalized(Array(slice[Int(startInSlice * sampleRate)...]), speechLevel: activity.speechLevel)
        let decoded = try await decoder(speech, prompt())
        let origin = sliceStart + startInSlice

        let segments: [DecodedSegment] = decoded.compactMap { segment in
            let text = TranscriptNoiseFilter.stripNoiseMarkers(segment.text)
            guard !text.isEmpty, !TranscriptNoiseFilter.isNoise(text, confidence: segment.confidence) else { return nil }
            return DecodedSegment(start: origin + segment.start, end: origin + segment.end, text: text, confidence: segment.confidence)
        }

        let trailingSilence = (sliceEnd - sliceStart) - lastSpeech
        let speakerFinished = final || trailingSilence >= config.flushSilenceSeconds
        let sliceIsFull = (sliceEnd - sliceStart) >= config.maxSliceSeconds - 0.5

        // How much of this decode is settled. The last few segments are held back, because with nothing
        // after them Whisper may still change them.
        var settle: Int
        if speakerFinished {
            settle = segments.count
        } else {
            settle = max(0, segments.count - config.unsettledSegments)
            // A full slice must make progress, or unbroken speech would be decoded again and again. If more
            // audio is already waiting behind it (we're catching up), take it all; the next slice starts there.
            if sliceIsFull { settle = max(settle, isCatchingUp ? segments.count : segments.count - 1) }
            // A segment still running at the very end of the audio isn't finished, wherever it falls.
            if !isCatchingUp {
                while settle > 0, segments[settle - 1].end > sliceEnd - 1.0 { settle -= 1 }
            }
        }

        var updates: [TranscriptSegment] = []
        for segment in segments.prefix(settle) {
            updates.append(makeSegment(segment, partial: false, id: UUID()))
            remember(segment.text)
        }
        if settle > 0 {
            committedEnd = max(committedEnd, segments[settle - 1].end)
        }
        if speakerFinished {
            // Nothing more is coming from this stretch of speech: move past it and its trailing silence.
            committedEnd = max(committedEnd, min(sliceEnd, sliceStart + lastSpeech + 0.2))
        } else if segments.isEmpty, (sliceEnd - sliceStart) >= 10 {
            // Speech-like sound that Whisper found nothing in (a cough, a keyboard): don't get stuck on it.
            committedEnd = max(committedEnd, sliceEnd - config.leadInSeconds)
        }

        let remaining = Array(segments.dropFirst(settle))
        if remaining.isEmpty {
            updates += clearTail()
        } else {
            tailSegments = remaining
            updates.append(tail(from: remaining))
        }
        return updates
    }

    // MARK: - Pieces

    private func makeSegment(_ segment: DecodedSegment, partial: Bool, id: UUID) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speakerId: speakerId,
            channel: channel,
            start: segment.start,
            end: segment.end,
            text: segment.text,
            isPartial: partial,
            confidence: segment.confidence
        )
    }

    /// The in-progress text as one segment, with the same id every time so it's replaced, not stacked.
    private func tail(from segments: [DecodedSegment]) -> TranscriptSegment {
        hasTail = true
        let confidences = segments.compactMap(\.confidence)
        return makeSegment(
            DecodedSegment(
                start: segments.first!.start,
                end: segments.last!.end,
                text: segments.map(\.text).joined(separator: " "),
                confidence: confidences.min()
            ),
            partial: true,
            id: tailID
        )
    }

    /// An empty in-progress segment: tells the merger to drop the old one.
    private func clearTail() -> [TranscriptSegment] {
        tailSegments = []
        guard hasTail else { return [] }
        hasTail = false
        return [makeSegment(DecodedSegment(start: committedEnd, end: committedEnd, text: ""), partial: true, id: tailID)]
    }

    private func remember(_ text: String) {
        committedText += (committedText.isEmpty ? "" : " ") + text
        if committedText.count > config.contextCharacters * 3 {
            committedText = String(committedText.suffix(config.contextCharacters * 2))
        }
    }

    /// The vocabulary, then the tail of what was just said: Whisper treats it as the text before the audio.
    private func prompt() -> String? {
        let recent = String(committedText.suffix(config.contextCharacters))
        let parts = [vocabulary, recent.isEmpty ? nil : recent].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Drop audio that's been committed, keeping a second of lead-in.
    private func trimBuffer() {
        let keepFrom = max(bufferStart, committedEnd - 1.0)
        let drop = Int((keepFrom - bufferStart) * sampleRate)
        guard drop > 0, drop < samples.count else { return }
        samples.removeFirst(drop)
        bufferStart += Double(drop) / sampleRate
    }
}
