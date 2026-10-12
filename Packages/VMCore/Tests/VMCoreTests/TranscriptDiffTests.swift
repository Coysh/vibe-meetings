import XCTest
@testable import VMCore

final class TranscriptDiffTests: XCTestCase {

    private func segment(_ text: String, _ start: TimeInterval, channel: AudioChannel = .system) -> TranscriptSegment {
        TranscriptSegment(
            speakerId: channel == .mic ? "you" : "others",
            channel: channel, start: start, end: start + 5, text: text
        )
    }

    private func texts(_ line: TranscriptDiff.Line, _ kind: TranscriptDiff.Kind) -> [String] {
        line.tokens.filter { $0.kind == kind }.map(\.text)
    }

    func testIdenticalTranscriptsHaveNoChanges() {
        let live = [segment("We should ship it on Friday.", 0)]
        let result = TranscriptDiff.compare(live: live, improved: live)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.liveWords, 6)
        XCTAssertEqual(result.improvedWords, 6)
    }

    func testWordsTheLiveTranscriptMissedAreMarkedAdded() {
        let live = [segment("we should ship the thing", 0)]
        let improved = [segment("we should ship the new thing on Friday", 0)]
        let result = TranscriptDiff.compare(live: live, improved: improved)
        XCTAssertEqual(texts(result.lines[0], .added), ["new", "on", "Friday"])
        XCTAssertEqual(result.added, 3)
        XCTAssertEqual(result.removed, 0)
    }

    func testAChangedWordShowsAsRemovedAndAdded() {
        let live = [segment("Teresa will send the notes", 0)]
        let improved = [segment("Theresa will send the notes", 0)]
        let result = TranscriptDiff.compare(live: live, improved: improved)
        XCTAssertEqual(texts(result.lines[0], .removed), ["Teresa"])
        XCTAssertEqual(texts(result.lines[0], .added), ["Theresa"])
    }

    func testCaseAndPunctuationAreIgnored() {
        let live = [segment("okay so, lets start", 0)]
        let improved = [segment("Okay. So, let\u{2019}s start!", 0)]
        let result = TranscriptDiff.compare(live: live, improved: improved)
        // "lets" vs "let's" is a real spelling difference; the rest matches despite case and punctuation.
        XCTAssertEqual(texts(result.lines[0], .removed), ["lets"])
        XCTAssertEqual(texts(result.lines[0], .added), ["let\u{2019}s"])
        XCTAssertEqual(result.lines[0].tokens.filter { $0.kind == .same }.map(\.text), ["Okay.", "So,", "start!"])
    }

    func testEachChannelIsComparedOnItsOwn() {
        // The two sides talk over each other in time; merging them would scramble the words.
        let live = [
            segment("yes I agree", 0, channel: .mic),
            segment("then let us begin", 1, channel: .system),
        ]
        let improved = [
            segment("then let us begin", 0, channel: .system),
            segment("yes I fully agree", 1, channel: .mic),
        ]
        let result = TranscriptDiff.compare(live: live, improved: improved)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(texts(result.lines[1], .added), ["fully"])
    }

    func testWordsOnlyTheLiveTranscriptHadAttachToTheNearestLine() {
        let live = [segment("uh so the budget", 0), segment("is approved", 5)]
        let improved = [segment("so the budget", 0), segment("is approved", 5)]
        let result = TranscriptDiff.compare(live: live, improved: improved)
        XCTAssertEqual(texts(result.lines[0], .removed), ["uh"])
        XCTAssertEqual(result.removed, 1)
    }

    func testAnImprovedSegmentWithNoWordsIsKept() {
        let live = [segment("hello there", 0)]
        let improved = [segment("hello there", 0), segment("", 5)]
        let result = TranscriptDiff.compare(live: live, improved: improved)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertTrue(result.lines[1].tokens.isEmpty)
    }

    func testNothingLiveMeansEverythingIsAdded() {
        let result = TranscriptDiff.compare(live: [], improved: [segment("a b c", 0)])
        XCTAssertEqual(result.added, 3)
        XCTAssertEqual(result.liveWords, 0)
    }

    func testAlignmentRebuildsBothSidesFromItsEdits() {
        // Property: applying the ops to either side reproduces both inputs, in order.
        let a = "the quick brown fox jumps over the lazy dog and the quick cat".split(separator: " ").map(String.init)
        let b = "a quick red fox jumped over the very lazy dog and then the quick cat sat".split(separator: " ").map(String.init)
        let ops = TranscriptDiff.align(a, b)
        var seenA: [Int] = [], seenB: [Int] = []
        for op in ops {
            switch op {
            case .equal(let i, let j):
                XCTAssertEqual(a[i], b[j])
                seenA.append(i); seenB.append(j)
            case .delete(let i): seenA.append(i)
            case .insert(let j): seenB.append(j)
            }
        }
        XCTAssertEqual(seenA, Array(a.indices))
        XCTAssertEqual(seenB, Array(b.indices))
    }

    func testALongTranscriptWithManyChangesIsFast() {
        // An hour of speech is ~9,000 words per side; the live pass can lose half of them.
        var generator = SystemRandomNumberGenerator()
        let vocabulary = (0..<600).map { "word\($0)" }
        let improvedWords = (0..<9000).map { _ in vocabulary.randomElement(using: &generator)! }
        var liveWords: [String] = []
        for word in improvedWords where Bool.random(using: &generator) { liveWords.append(word) }

        let improved = stride(from: 0, to: improvedWords.count, by: 20).map {
            segment(improvedWords[$0..<min($0 + 20, improvedWords.count)].joined(separator: " "), TimeInterval($0))
        }
        let live = stride(from: 0, to: liveWords.count, by: 20).map {
            segment(liveWords[$0..<min($0 + 20, liveWords.count)].joined(separator: " "), TimeInterval($0))
        }

        let started = Date()
        let result = TranscriptDiff.compare(live: live, improved: improved)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        // Every improved word is either shared with the live transcript or added.
        XCTAssertEqual(result.improvedWords, 9000)
        XCTAssertEqual(result.liveWords, liveWords.count)
        XCTAssertEqual(result.improvedWords - result.added, result.liveWords - result.removed)
    }
}
