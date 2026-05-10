import XCTest
@testable import VMCalendar

final class TeamsURLDetectorTests: XCTestCase {
    func testDetectsMeetupJoinURL() {
        let s = "Join here: https://teams.microsoft.com/l/meetup-join/19%3ameeting_FAKE/0?context=%7b%22Tid%22%3a%22abc%22%7d more text"
        let url = TeamsURLDetector.detect(in: s)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "teams.microsoft.com")
        XCTAssertTrue(url?.path.hasPrefix("/l/meetup-join/") == true)
    }

    func testDetectsLiveMeetURL() {
        let s = "Quick chat: https://teams.live.com/meet/9876543210"
        XCTAssertNotNil(TeamsURLDetector.detect(in: s))
    }

    func testDetectsTenantMeetURL() {
        let s = "https://teams.microsoft.com/meet/2345?p=foo"
        XCTAssertNotNil(TeamsURLDetector.detect(in: s))
    }

    func testCaseInsensitive() {
        let s = "HTTPS://Teams.Microsoft.Com/l/meetup-join/19%3aFAKE/0"
        XCTAssertNotNil(TeamsURLDetector.detect(in: s))
    }

    func testReturnsFirstMatchOfMany() {
        let s = """
        First: https://teams.microsoft.com/l/meetup-join/19%3aONE/0
        Second: https://teams.microsoft.com/l/meetup-join/19%3aTWO/0
        """
        XCTAssertEqual(
            TeamsURLDetector.detect(in: s)?.absoluteString,
            "https://teams.microsoft.com/l/meetup-join/19%3aONE/0"
        )
    }

    func testNoMatchInUnrelatedText() {
        XCTAssertNil(TeamsURLDetector.detect(in: "Zoom: https://zoom.us/j/12345"))
        XCTAssertNil(TeamsURLDetector.detect(in: "Meet: https://meet.google.com/abc-defg-hij"))
        XCTAssertNil(TeamsURLDetector.detect(in: ""))
    }

    func testDoesNotMatchWrongPath() {
        let s = "https://teams.microsoft.com/randomthing"
        XCTAssertNil(TeamsURLDetector.detect(in: s))
    }

    func testDetectInAnyScansAllStrings() {
        let inputs = [
            "no link here",
            "still nothing",
            "third: https://teams.live.com/meet/42 yes"
        ]
        XCTAssertNotNil(TeamsURLDetector.detect(inAny: inputs))
    }

    func testStopsAtWhitespaceAndQuotes() {
        let s = "<a href=\"https://teams.microsoft.com/l/meetup-join/19%3aFAKE/0\">Join</a>"
        let url = TeamsURLDetector.detect(in: s)
        XCTAssertNotNil(url)
        XCTAssertFalse(url?.absoluteString.contains("\"") == true)
    }
}
