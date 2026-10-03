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

    // MARK: - Union / order-aware matching (v2)

    /// The echo's text is split across three system segments because the two
    /// channels are windowed independently. The single-segment rule missed this.
    func testEchoSplitAcrossThreeSystemSegmentsDropped() {
        let segs = [
            system("we need to revisit the", 10.0, 11.5),
            system("pricing model before the", 11.5, 13.0),
            system("board meeting next week", 13.0, 14.5),
            mic("revisit the pricing model before the board meeting", 11.0, 14.0)
        ]
        let out = EchoDedup.suppress(segs)
        XCTAssertTrue(texts(out, .mic).isEmpty)
    }

    /// Mic and system segment boundaries drift by a few seconds.
    func testBoundaryDriftStillCaught() {
        let segs = [
            system("the migration to the new platform finishes on thursday", 20.0, 24.0),
            mic("migration to the new platform finishes on thursday", 22.5, 26.5)
        ]
        let out = EchoDedup.suppress(segs)
        XCTAssertTrue(texts(out, .mic).isEmpty)
    }

    /// Reverb garbles a word ("deadlined"); one-letter slips still match.
    func testReverbGarbledWordStillMatches() {
        let segs = [
            system("please move the deadline to the end of the month", 5.0, 8.0),
            mic("please move the deadlined to the end of the month", 5.1, 8.1)
        ]
        XCTAssertTrue(texts(EchoDedup.suppress(segs), .mic).isEmpty)
    }

    /// The user talks over the tail of the other party: only the echoed span is
    /// removed, the user's own words (and a sensible time range) survive.
    func testMixedSegmentTrimmedKeepsUserWords() {
        let segs = [
            system("the quarterly numbers look strong this time", 30.0, 33.0),
            mic("the quarterly numbers look strong this time and I disagree with the forecast", 30.0, 36.0)
        ]
        let out = EchoDedup.suppress(segs)
        let kept = out.filter { $0.channel == .mic }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].text, "and I disagree with the forecast")
        XCTAssertGreaterThan(kept[0].start, 30.0, "start should move past the removed echo")
        XCTAssertEqual(kept[0].end, 36.0, accuracy: 0.001)
    }

    /// Same words, reversed order: not an echo (the match is order-aware).
    func testReversedOrderIsKept() {
        let segs = [
            system("alpha bravo charlie delta echo foxtrot", 40.0, 43.0),
            mic("foxtrot echo delta charlie bravo alpha", 40.0, 43.0)
        ]
        XCTAssertEqual(texts(EchoDedup.suppress(segs), .mic).count, 1)
    }

    /// A one-word fragment that is a distinctive word the other party just said
    /// is dropped; a backchannel "yeah" never is.
    func testOneWordFragments() {
        let segs = [
            system("we are over the budget again", 50.0, 52.0),
            mic("budget", 50.8, 51.2),
            mic("yeah", 51.5, 51.8)
        ]
        let kept = texts(EchoDedup.suppress(segs), .mic)
        XCTAssertEqual(kept, ["yeah"])
    }

    /// The user quoting a short phrase a few seconds *later* is not echo.
    func testUserQuotingPhraseLaterIsKept() {
        let segs = [
            system("the contract renewal is due friday", 60.0, 62.0),
            mic("so the contract renewal is due friday", 66.5, 68.5)
        ]
        XCTAssertEqual(texts(EchoDedup.suppress(segs), .mic).count, 1)
    }

    /// Overlap made only of function words is never enough.
    func testFunctionWordOnlyOverlapKept() {
        let segs = [
            system("i think that we should", 70.0, 72.0),
            mic("i think that we should", 70.0, 72.0)
        ]
        XCTAssertEqual(texts(EchoDedup.suppress(segs), .mic).count, 1)
    }

    /// `.conservative` is the original single-segment behaviour: echo split across
    /// several system segments is *not* caught.
    func testConservativeConfigKeepsOldBehaviour() {
        let segs = [
            system("we need to revisit the", 10.0, 11.5),
            system("pricing model before the", 11.5, 13.0),
            system("board meeting next week", 13.0, 14.5),
            mic("revisit the pricing model before the board meeting", 11.0, 14.0)
        ]
        XCTAssertEqual(texts(EchoDedup.suppress(segs, config: .conservative), .mic).count, 1)
    }

    /// 500 segments must stay cheap — this runs on every live transcript update.
    func testPerformanceOnLongMeeting() {
        var segs: [TranscriptSegment] = []
        for i in 0..<250 {
            let t = Double(i) * 6
            segs.append(system("segment \(i) discusses topic alpha beta gamma delta epsilon zeta", t, t + 5))
            segs.append(mic("my own reply number \(i) about something entirely different here", t + 0.5, t + 5))
        }
        let start = Date()
        _ = EchoDedup.suppress(segs)
        // Generous: debug builds are far slower than release.
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
