import XCTest
@testable import VMCore

final class EchoDedupTests: XCTestCase {

    private func mic(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speakerId: "you", channel: .mic, start: start, end: end, text: text)
    }

    private func system(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speakerId: "others", channel: .system, start: start, end: end, text: text)
    }

    private func texts(_ segs: [TranscriptSegment], _ channel: AudioChannel) -> [String] {
        segs.filter { $0.channel == channel }.map(\.text)
    }

    /// A near-perfect echo (mic transcribed the other party verbatim) is dropped.
    func testExactEchoDropped() {
        let segs = [
            system("let's move the deadline to next friday", 10.0, 12.0),
            mic("let's move the deadline to next friday", 10.07, 12.1)
        ]
        let out = EchoDedup.suppress(segs)
        XCTAssertTrue(texts(out, .mic).isEmpty, "verbatim echo should be removed from the mic channel")
        XCTAssertEqual(texts(out, .system).count, 1, "system (ground-truth) segments are never dropped")
    }

    /// The regression this change targets: the mic captured the echo *partially*
    /// (some words dropped, none added). Symmetric Jaccard fell below 0.8 and let
    /// it through; directional containment catches it.
    func testPartialEchoDropped() {
        let segs = [
            system("we should probably ship the release on monday morning", 5.0, 7.5),
            // mic dropped "probably", "release", "morning" — 6 of 9 words survive,
            // Jaccard = 6/9 = 0.67 (kept before); containment = 6/6 = 1.0 (dropped now).
            mic("we should ship the on monday", 5.06, 7.4)
        ]
        let out = EchoDedup.suppress(segs)
        XCTAssertTrue(texts(out, .mic).isEmpty, "partial (word-dropping) echo should now be removed")
    }

    /// When the user talks *over* the other party, the mic segment carries genuine
    /// words the system channel never saw, so it must be kept (dropping it would
    /// lose real speech). The extra words keep containment below threshold, and the
    /// length guard also excludes it.
    func testUserSpeakingOverEchoIsKept() {
        let segs = [
            system("can everyone see my screen now", 20.0, 22.0),
            mic("yes i can see it and i wanted to add one more thing about the budget", 20.1, 23.5)
        ]
        let out = EchoDedup.suppress(segs)
        XCTAssertEqual(texts(out, .mic).count, 1, "genuine user speech overlapping the other party must be preserved")
    }

    /// Genuine simultaneous agreement — same idea, different (paraphrased) words —
    /// stays because the mic's words are not contained in the system text.
    func testGenuineParaphrasedAgreementKept() {
        let segs = [
            system("i think we should go with the first option", 30.0, 32.0),
            mic("yeah absolutely that one works for me", 30.2, 32.1)
        ]
        let out = EchoDedup.suppress(segs)
        XCTAssertEqual(texts(out, .mic).count, 1, "paraphrased agreement is not echo and must be kept")
    }

    /// Short backchannel is never treated as echo, even if it matches.
    func testShortBackchannelKept() {
        let segs = [
            system("right exactly that makes sense to me", 40.0, 42.0),
            mic("right exactly", 40.1, 40.6)
        ]
        let out = EchoDedup.suppress(segs)
        XCTAssertEqual(texts(out, .mic).count, 1, "sub-minWords mic segments are always kept")
    }

    /// A matching system line far outside the time tolerance is not the source.
    func testDistantMatchNotTreatedAsEcho() {
        let segs = [
            system("the quarterly numbers look strong this time", 0.0, 2.0),
            mic("the quarterly numbers look strong this time", 60.0, 62.0)
        ]
        let out = EchoDedup.suppress(segs)
        XCTAssertEqual(texts(out, .mic).count, 1, "a temporally distant match is coincidence, not echo")
    }

    /// With no system reference at all, nothing is dropped.
    func testNoSystemReferenceKeepsEverything() {
        let segs = [mic("we should ship the on monday", 5.0, 7.0)]
        let out = EchoDedup.suppress(segs)
        XCTAssertEqual(out.count, 1)
    }
}
