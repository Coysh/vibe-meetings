import XCTest
@testable import VMCore

final class TranscriptNoiseFilterTests: XCTestCase {
    func testRemovesSoundAnnotationsFromInsideALine() {
        // Taken from a real live transcript.
        XCTAssertEqual(
            TranscriptNoiseFilter.stripNoiseMarkers("Hi Tim. [silence] I can't, you're on mute by the way. How are you? [END] It's a serious thing."),
            "Hi Tim. I can't, you're on mute by the way. How are you? It's a serious thing."
        )
        XCTAssertEqual(TranscriptNoiseFilter.stripNoiseMarkers("[POP] [silence] Hi Tim."), "Hi Tim.")
        XCTAssertEqual(TranscriptNoiseFilter.stripNoiseMarkers("Well [ Silence ] yes"), "Well yes")
    }

    func testRemovesNoiseInRoundBracketsButKeepsSpeech() {
        XCTAssertEqual(TranscriptNoiseFilter.stripNoiseMarkers("Okay (keyboard clicking) so next"), "Okay so next")
        // Real parenthetical speech stays.
        XCTAssertEqual(
            TranscriptNoiseFilter.stripNoiseMarkers("We spoke to Paul (the new starter) yesterday"),
            "We spoke to Paul (the new starter) yesterday"
        )
    }

    func testMusicNotesAndSpacingBeforePunctuation() {
        XCTAssertEqual(TranscriptNoiseFilter.stripNoiseMarkers("♪ Yes ♪"), "Yes")
        XCTAssertEqual(TranscriptNoiseFilter.stripNoiseMarkers("Right [pause] , okay."), "Right, okay.")
    }

    func testPlainTextIsUntouched() {
        let text = "Let's lock the budget at 40k for phase one."
        XCTAssertEqual(TranscriptNoiseFilter.stripNoiseMarkers(text), text)
    }

    func testAWholeLineOfNoiseBecomesEmpty() {
        XCTAssertEqual(TranscriptNoiseFilter.stripNoiseMarkers("[silence]"), "")
        XCTAssertEqual(TranscriptNoiseFilter.stripNoiseMarkers("  [BLANK_AUDIO] "), "")
    }
}
