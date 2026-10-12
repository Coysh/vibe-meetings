import XCTest
import VMCore
@testable import VMTranscription

/// Drives `LiveTranscriptionSession` with synthetic audio: each "utterance" is a tone of its own pitch, and
/// the fake decoder "transcribes" a tone as its number. That's enough to check what matters about the
/// commit-and-advance logic — nothing lost, nothing repeated, settled text never changes, silence never
/// reaches the model — without a speech model.
final class LiveTranscriptionSessionTests: XCTestCase {
    private let rate = 16_000.0

    // MARK: Synthetic audio

    struct Utterance { let start: Double; let duration: Double; let id: Int }

    /// `seconds` of silence with a tone for each utterance (pitch = 200 Hz × id).
    private func audio(_ utterances: [Utterance], seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        for u in utterances {
            let first = Int(u.start * rate), count = Int(u.duration * rate)
            let frequency = 200.0 * Double(u.id)
            for i in 0..<count where first + i < samples.count {
                samples[first + i] = Float(0.2 * sin(2 * .pi * frequency * Double(i) / rate))
            }
        }
        return samples
    }

    /// A stand-in for Whisper: finds each burst of sound (separated by at least half a second of quiet) and
    /// reports it as "u<pitch/200>". It sees only the samples, like the real thing.
    final class FakeWhisper: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private(set) var silentCalls = 0

        func decode(_ samples: [Float]) -> [DecodedSegment] {
            lock.lock(); calls += 1; lock.unlock()
            let frame = 320
            let loud = (0..<(samples.count / frame)).map { f -> Bool in
                var energy: Float = 0
                for i in 0..<frame { energy += samples[f * frame + i] * samples[f * frame + i] }
                return (energy / Float(frame)).squareRoot() > 0.02
            }
            var runs: [(Int, Int)] = []
            var i = 0
            while i < loud.count {
                guard loud[i] else { i += 1; continue }
                var j = i
                var lastLoud = i
                while j < loud.count, j - lastLoud < 25 { if loud[j] { lastLoud = j }; j += 1 }
                runs.append((i, lastLoud + 1))
                i = lastLoud + 1
            }
            if runs.isEmpty { lock.lock(); silentCalls += 1; lock.unlock() }
            return runs.map { run in
                var crossings = 0
                for k in (run.0 * frame + 1)..<(run.1 * frame) where (samples[k - 1] < 0) != (samples[k] < 0) { crossings += 1 }
                let seconds = Double(run.1 - run.0) * 0.02
                let pitch = Double(crossings) / 2 / seconds
                return DecodedSegment(start: Double(run.0) * 0.02, end: Double(run.1) * 0.02, text: "u\(Int((pitch / 200).rounded()))", confidence: -0.2)
            }
        }
    }

    private func makeSession(_ whisper: FakeWhisper) -> LiveTranscriptionSession {
        LiveTranscriptionSession(channel: .system, speakerId: "others", vocabulary: nil) { samples, _ in whisper.decode(samples) }
    }

    /// Feed `samples` in 0.5 s chunks (as capture would), merging updates the way the app does.
    private func run(_ session: LiveTranscriptionSession, samples: [Float], chunk: Double = 0.5) async throws -> (merger: SegmentMerger, updates: [TranscriptSegment]) {
        let merger = SegmentMerger()
        var updates: [TranscriptSegment] = []
        let step = Int(chunk * rate)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + step)
            for update in try await session.ingest(PCMChunk(samples: Array(samples[index..<end]), timestamp: Double(index) / rate)) {
                updates.append(update); merger.ingest(update)
            }
            index = end
        }
        for update in try await session.finish() { updates.append(update); merger.ingest(update) }
        return (merger, updates)
    }

    private func texts(_ merger: SegmentMerger) -> [String] { merger.snapshot().map(\.text) }

    // MARK: Tests

    func testEveryUtteranceAppearsOnceAndInOrder() async throws {
        let utterances = (1...8).map { Utterance(start: Double($0) * 4.0, duration: 2.5, id: $0) }
        let whisper = FakeWhisper()
        let (merger, _) = try await run(makeSession(whisper), samples: audio(utterances, seconds: 40))

        XCTAssertEqual(texts(merger), (1...8).map { "u\($0)" })
        XCTAssertTrue(merger.snapshot().allSatisfy { !$0.isPartial } || merger.finalSnapshot().allSatisfy { !$0.isPartial })
    }

    func testNothingIsLostWhenSpeechRunsStraightOn() async throws {
        // Utterances with only a short pause between them, so windows never land on a silence.
        let utterances = (1...12).map { Utterance(start: Double($0 - 1) * 3.0, duration: 2.4, id: $0) }
        let (merger, _) = try await run(makeSession(FakeWhisper()), samples: audio(utterances, seconds: 38))
        XCTAssertEqual(texts(merger), (1...12).map { "u\($0)" })
    }

    func testSettledTextNeverChanges() async throws {
        let utterances = (1...6).map { Utterance(start: Double($0) * 5.0, duration: 3.0, id: $0) }
        let (_, updates) = try await run(makeSession(FakeWhisper()), samples: audio(utterances, seconds: 40))

        let settled = updates.filter { !$0.isPartial }
        // Each settled segment is announced exactly once.
        XCTAssertEqual(Set(settled.map(\.id)).count, settled.count)
        XCTAssertEqual(settled.map(\.text), (1...6).map { "u\($0)" })
    }

    func testInProgressTextIsRewrittenInPlace() async throws {
        let utterances = [Utterance(start: 1, duration: 9, id: 3)]
        let (_, updates) = try await run(makeSession(FakeWhisper()), samples: audio(utterances, seconds: 14))
        let partials = updates.filter(\.isPartial)
        XCTAssertGreaterThan(partials.count, 1, "a long utterance should be shown as it firms up")
        XCTAssertEqual(Set(partials.map(\.id)).count, 1, "the in-progress text keeps one id so it replaces itself")
    }

    func testSilenceNeverReachesTheModel() async throws {
        let utterances = [Utterance(start: 20, duration: 2, id: 2)]
        let whisper = FakeWhisper()
        let (merger, _) = try await run(makeSession(whisper), samples: audio(utterances, seconds: 40))

        XCTAssertEqual(texts(merger), ["u2"])
        XCTAssertEqual(whisper.silentCalls, 0, "decoding pure silence is how Whisper invents text")
        // 18 s of silence before the speech and 18 s after: far fewer decodes than hops.
        XCTAssertLessThan(whisper.calls, 6)
    }

    func testAllAudioArrivingAtOnceIsStillDecodedInFull() async throws {
        // Models that fall behind get a backlog; it should be worked through, not skipped.
        let utterances = (1...10).map { Utterance(start: Double($0) * 5.0, duration: 3.0, id: $0) }
        let samples = audio(utterances, seconds: 60)
        let session = makeSession(FakeWhisper())
        let merger = SegmentMerger()
        for update in try await session.ingest(PCMChunk(samples: samples, timestamp: 0)) { merger.ingest(update) }
        for update in try await session.finish() { merger.ingest(update) }
        XCTAssertEqual(texts(merger), (1...10).map { "u\($0)" })
    }

    func testWhatWasInProgressWhenTheAudioEndsIsKept() async throws {
        // Speech running right up to the end of the recording: nothing is silent, so nothing settles on its own.
        let utterances = [Utterance(start: 0.5, duration: 5.2, id: 4)]
        let session = makeSession(FakeWhisper())
        let merger = SegmentMerger()
        for update in try await session.ingest(PCMChunk(samples: audio(utterances, seconds: 6), timestamp: 0)) { merger.ingest(update) }
        for update in try await session.finish() { merger.ingest(update) }

        XCTAssertEqual(merger.snapshot().map(\.text), ["u4"])
        XCTAssertTrue(merger.snapshot().allSatisfy { !$0.isPartial }, "settled, not left in progress")
    }

    func testALongPauseInCaptureKeepsTimesHonest() async throws {
        let whisper = FakeWhisper()
        let session = makeSession(whisper)
        let before = audio([Utterance(start: 1, duration: 2, id: 1)], seconds: 8)
        let after = audio([Utterance(start: 1, duration: 2, id: 2)], seconds: 8)
        let merger = SegmentMerger()
        for update in try await session.ingest(PCMChunk(samples: before, timestamp: 0)) { merger.ingest(update) }
        // The capture clock jumps 5 minutes (recording was paused).
        for update in try await session.ingest(PCMChunk(samples: after, timestamp: 308)) { merger.ingest(update) }
        for update in try await session.finish() { merger.ingest(update) }

        let segments = merger.snapshot()
        XCTAssertEqual(segments.map(\.text), ["u1", "u2"])
        XCTAssertEqual(segments[1].start, 309, accuracy: 0.6, "the second utterance lands where it really happened")
    }

    func testPromptCarriesRecentlySettledText() async throws {
        let prompts = PromptLog()
        let whisper = FakeWhisper()
        var configuration = LiveTranscriptionSession.Configuration()
        configuration.contextCharacters = 160   // off by default; this test is about what it carries when on
        let session = LiveTranscriptionSession(channel: .mic, speakerId: "you", vocabulary: "Names: Coysh.", configuration: configuration) { samples, prompt in
            prompts.add(prompt)
            return whisper.decode(samples)
        }
        let utterances = (1...5).map { Utterance(start: Double($0) * 5.0, duration: 3.0, id: $0) }
        _ = try await run(session, samples: audio(utterances, seconds: 35))

        XCTAssertTrue(prompts.all.allSatisfy { $0?.hasPrefix("Names: Coysh.") == true }, "the vocabulary leads every prompt")
        XCTAssertTrue(prompts.all.contains { $0?.contains("u1") == true }, "later decodes get earlier text as context")
    }

    final class PromptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String?] = []
        func add(_ prompt: String?) { lock.lock(); prompts.append(prompt); lock.unlock() }
        var all: [String?] { lock.lock(); defer { lock.unlock() }; return prompts }
    }
}

final class SegmentMergerReplacementTests: XCTestCase {
    func testASegmentSentAgainWithTheSameIdReplacesItself() {
        let merger = SegmentMerger()
        let id = UUID()
        merger.ingest(TranscriptSegment(id: id, speakerId: "you", channel: .mic, start: 0, end: 2, text: "so we were", isPartial: true))
        merger.ingest(TranscriptSegment(id: id, speakerId: "you", channel: .mic, start: 0, end: 3, text: "so we were talking about the budget", isPartial: true))
        XCTAssertEqual(merger.snapshot().map(\.text), ["so we were talking about the budget"])
    }

    func testAnEmptyResendRemovesIt() {
        let merger = SegmentMerger()
        let id = UUID()
        merger.ingest(TranscriptSegment(id: id, speakerId: "you", channel: .mic, start: 0, end: 2, text: "hello there", isPartial: true))
        merger.ingest(TranscriptSegment(id: id, speakerId: "you", channel: .mic, start: 0, end: 2, text: "", isPartial: true))
        XCTAssertTrue(merger.snapshot().isEmpty)
    }

    func testEmbeddedNoiseMarkersAreStripped() {
        let merger = SegmentMerger()
        merger.ingest(TranscriptSegment(speakerId: "others", channel: .system, start: 0, end: 3, text: "Hi Tim. [silence] How are you? [END]"))
        XCTAssertEqual(merger.snapshot().map(\.text), ["Hi Tim. How are you?"])
    }
}

final class SpeechActivityTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * Float(sin(2 * .pi * 300 * Double($0) / 16_000)) }
    }

    func testSilenceHasNoSpeech() {
        XCTAssertFalse(SpeechActivity.analyze([Float](repeating: 0, count: 32_000)).hasSpeech)
    }

    func testRoomNoiseAloneIsNotSpeech() {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<48_000).map { _ in Float.random(in: -0.002...0.002, using: &generator) }
        XCTAssertFalse(SpeechActivity.analyze(noise).hasSpeech)
    }

    func testFindsWhereSpeechStartsAndStops() {
        let samples = [Float](repeating: 0, count: 32_000) + tone(2) + [Float](repeating: 0, count: 48_000)
        let analysis = SpeechActivity.analyze(samples)
        XCTAssertEqual(analysis.firstSpeech ?? -1, 2.0, accuracy: 0.1)
        XCTAssertEqual(analysis.lastSpeech ?? -1, 4.0, accuracy: 0.1)
    }

    func testAPauseBetweenWordsDoesNotSplitSpeech() {
        let samples = tone(1) + [Float](repeating: 0, count: 3_200) + tone(1)   // 0.2 s gap
        let analysis = SpeechActivity.analyze(samples)
        XCTAssertEqual(analysis.firstSpeech ?? -1, 0, accuracy: 0.05)
        XCTAssertEqual(analysis.lastSpeech ?? -1, 2.2, accuracy: 0.1)
    }

    func testSpeechFromTheFirstSecondIsStillSpeech() {
        // Nothing quiet to measure a noise floor from: all of it is talking.
        XCTAssertTrue(SpeechActivity.analyze(tone(3)).hasSpeech)
        XCTAssertTrue(SpeechActivity.analyze(tone(3, amplitude: 0.01)).hasSpeech, "even quiet speech")
    }

    func testAKnownNoisyRoomRaisesTheBar() {
        var generator = SystemRandomNumberGenerator()
        let hiss = (0..<48_000).map { _ in Float.random(in: -0.004...0.004, using: &generator) }   // about -53 dBFS
        let withKnownFloor = SpeechActivity.analyze(hiss, noiseFloor: -52)
        XCTAssertFalse(withKnownFloor.hasSpeech)
    }

    func testAClickIsNotSpeech() {
        var samples = [Float](repeating: 0, count: 32_000)
        for i in 16_000..<16_800 { samples[i] = 0.5 }   // 50 ms
        XCTAssertFalse(SpeechActivity.analyze(samples).hasSpeech)
    }

    func testQuietSpeechIsBroughtUpButNoisyAudioIsNot() {
        let quiet = tone(1, amplitude: 0.01)
        let analysis = SpeechActivity.analyze(quiet)
        let boosted = SpeechActivity.normalized(quiet, speechLevel: analysis.speechLevel)
        XCTAssertGreaterThan(boosted.map(abs).max() ?? 0, 0.03)
        XCTAssertLessThanOrEqual(boosted.map(abs).max() ?? 0, 1)

        let loud = tone(1, amplitude: 0.3)
        XCTAssertEqual(SpeechActivity.normalized(loud, speechLevel: SpeechActivity.analyze(loud).speechLevel), loud)
    }
}
