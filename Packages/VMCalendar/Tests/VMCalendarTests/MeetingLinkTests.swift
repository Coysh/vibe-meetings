import XCTest
import VMCore
@testable import VMCalendar

final class MeetingURLDetectorTests: XCTestCase {
    func testTeams() {
        let link = MeetingURLDetector.detect(in: "Join: https://teams.microsoft.com/l/meetup-join/19%3aFAKE/0?context=x")
        XCTAssertEqual(link?.platform, .teams)
    }

    func testZoomVariants() {
        XCTAssertEqual(MeetingURLDetector.detect(in: "https://us02web.zoom.us/j/81234567890?pwd=abc")?.platform, .zoom)
        XCTAssertEqual(MeetingURLDetector.detect(in: "https://zoom.us/my/someone")?.platform, .zoom)
        XCTAssertEqual(MeetingURLDetector.detect(in: "https://agency.zoomgov.com/j/1234")?.platform, .zoom)
        XCTAssertEqual(MeetingURLDetector.detect(in: "zoommtg://zoom.us/join?confno=123")?.platform, .zoom)
    }

    func testZoomMarketingPagesAreNotJoinLinks() {
        XCTAssertNil(MeetingURLDetector.detect(in: "See https://zoom.us/pricing for plans"))
    }

    func testGoogleMeet() {
        let link = MeetingURLDetector.detect(in: "Video call link: https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(link?.platform, .googleMeet)
        XCTAssertEqual(link?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testWebex() {
        XCTAssertEqual(MeetingURLDetector.detect(in: "https://acme.webex.com/meet/jdoe")?.platform, .webex)
        XCTAssertEqual(MeetingURLDetector.detect(in: "https://acme.webex.com/acme/j.php?MTID=m123")?.platform, .webex)
    }

    func testStripsTrailingPunctuationAndOutlookWrapping() {
        let link = MeetingURLDetector.detect(in: "Join here <https://meet.google.com/abc-defg-hij>.")
        XCTAssertEqual(link?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
        let zoom = MeetingURLDetector.detect(in: "Join (https://zoom.us/j/123?pwd=x).")
        XCTAssertEqual(zoom?.url.absoluteString, "https://zoom.us/j/123?pwd=x")
    }

    func testDecodesHTMLAmpersands() {
        let link = MeetingURLDetector.detect(in: "https://zoom.us/j/123?pwd=x&amp;uname=y")
        XCTAssertEqual(link?.url.absoluteString, "https://zoom.us/j/123?pwd=x&uname=y")
    }

    func testEarliestLinkInStringWins() {
        let s = "Dial-in via https://zoom.us/j/111 or fallback https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(MeetingURLDetector.detect(in: s)?.platform, .zoom)
    }

    func testFirstStringWins() {
        let link = MeetingURLDetector.detect(inAny: ["no link here", "https://meet.google.com/abc-defg-hij", "https://zoom.us/j/1"])
        XCTAssertEqual(link?.platform, .googleMeet)
    }

    func testTeamsWrapperIgnoresEarlierNonTeamsLink() {
        let s = "https://zoom.us/j/1 then https://teams.microsoft.com/l/meetup-join/19%3aX/0"
        XCTAssertEqual(TeamsURLDetector.detect(in: s)?.host, "teams.microsoft.com")
    }

    func testNoLink() {
        XCTAssertNil(MeetingURLDetector.detect(in: "Room 4B, bring snacks"))
    }
}

private func event(
    id: String = "e1",
    title: String = "Weekly sync",
    start: Date,
    minutes: Double = 30,
    link: MeetingLink? = nil
) -> CalendarEvent {
    CalendarEvent(
        id: id, seriesID: "s-\(id)", title: title,
        startDate: start, endDate: start.addingTimeInterval(minutes * 60),
        location: nil, notes: nil, meetingLink: link,
        calendarID: "cal", calendarTitle: "Work"
    )
}

private let zoomLink = MeetingLink(url: URL(string: "https://zoom.us/j/1")!, platform: .zoom)
private let meetLink = MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, platform: .googleMeet)

final class CalendarEventLinkTests: XCTestCase {
    func testTeamsShimsStillWork() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/x")!
        let ev = CalendarEvent(id: "1", seriesID: "s", title: "t", startDate: .now, endDate: .now,
                               location: nil, notes: nil, teamsJoinURL: url,
                               calendarID: "c", calendarTitle: "C")
        XCTAssertTrue(ev.hasTeamsURL)
        XCTAssertEqual(ev.platform, .teams)
        XCTAssertEqual(ev.teamsJoinURL, url)
    }

    func testNonTeamsLinkIsNotTeams() {
        let ev = event(start: .now, link: zoomLink)
        XCTAssertFalse(ev.hasTeamsURL)
        XCTAssertTrue(ev.hasMeetingLink)
        XCTAssertEqual(ev.platform, .zoom)
    }
}

final class CurrentEventMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testPicksInProgressEvent() {
        let ev = event(start: now.addingTimeInterval(-600))
        XCTAssertEqual(CurrentEventMatcher.bestMatch(events: [ev], now: now)?.id, "e1")
    }

    func testIncludesEventStartingSoonButNotLater() {
        let soon = event(id: "soon", start: now.addingTimeInterval(5 * 60))
        let later = event(id: "later", start: now.addingTimeInterval(40 * 60))
        XCTAssertEqual(CurrentEventMatcher.bestMatch(events: [soon, later], now: now)?.id, "soon")
        XCTAssertNil(CurrentEventMatcher.bestMatch(events: [later], now: now))
    }

    func testEndedEventIgnored() {
        let ended = event(start: now.addingTimeInterval(-3600))
        XCTAssertNil(CurrentEventMatcher.bestMatch(events: [ended], now: now))
    }

    func testPlatformHintBreaksOverlap() {
        let zoom = event(id: "zoom", start: now.addingTimeInterval(-60), link: zoomLink)
        let meet = event(id: "meet", start: now.addingTimeInterval(-30), link: meetLink)
        XCTAssertEqual(CurrentEventMatcher.bestMatch(events: [zoom, meet], now: now, platformHint: .zoom)?.id, "zoom")
        XCTAssertEqual(CurrentEventMatcher.bestMatch(events: [zoom, meet], now: now)?.id, "meet")
    }

    func testOnlineEventPreferredOverInPersonOverlap() {
        let inPerson = event(id: "lunch", start: now.addingTimeInterval(-10))
        let online = event(id: "call", start: now.addingTimeInterval(-300), link: zoomLink)
        XCTAssertEqual(CurrentEventMatcher.bestMatch(events: [inPerson, online], now: now)?.id, "call")
    }
}

final class EventReminderPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testPlansLeadAndAtStartForOnlineMeeting() {
        let ev = event(start: now.addingTimeInterval(600), link: zoomLink)
        let plan = EventReminderPlanner.plan(events: [ev], now: now, leadMinutes: 3, atStart: true)
        XCTAssertEqual(plan.map(\.kind), [.lead(minutes: 3), .atStart])
        XCTAssertEqual(plan[0].fireDate, now.addingTimeInterval(420))
        XCTAssertEqual(plan[1].fireDate, ev.startDate)
    }

    func testNoAtStartWithoutLink() {
        let ev = event(start: now.addingTimeInterval(600))
        let plan = EventReminderPlanner.plan(events: [ev], now: now, leadMinutes: 3, atStart: true)
        XCTAssertEqual(plan.map(\.kind), [.lead(minutes: 3)])
    }

    func testSkipsPastFireDatesAndStartedEvents() {
        let soon = event(id: "soon", start: now.addingTimeInterval(60), link: zoomLink)   // lead already passed
        let started = event(id: "started", start: now.addingTimeInterval(-60))
        let plan = EventReminderPlanner.plan(events: [soon, started], now: now, leadMinutes: 3, atStart: true)
        XCTAssertEqual(plan.map(\.kind), [.atStart])
        XCTAssertEqual(plan.first?.event.id, "soon")
    }

    func testLeadDisabled() {
        let ev = event(start: now.addingTimeInterval(600), link: zoomLink)
        XCTAssertEqual(EventReminderPlanner.plan(events: [ev], now: now, leadMinutes: nil, atStart: false), [])
    }

    func testMovedEventReconciles() {
        let original = event(start: now.addingTimeInterval(600))
        let moved = event(start: now.addingTimeInterval(1800))
        let old = EventReminderPlanner.plan(events: [original], now: now, leadMinutes: 3, atStart: false)
        let new = EventReminderPlanner.plan(events: [moved], now: now, leadMinutes: 3, atStart: false)
        let diff = EventReminderPlanner.diff(planned: new, pendingIDs: Set(old.map(\.identifier)))
        XCTAssertEqual(diff.add.map(\.identifier), new.map(\.identifier))
        XCTAssertEqual(diff.remove, old.map(\.identifier))
    }

    func testCancelledEventRemovedAndUnrelatedIDsKept() {
        let ev = event(start: now.addingTimeInterval(600))
        let old = EventReminderPlanner.plan(events: [ev], now: now, leadMinutes: 3, atStart: false)
        let pending = Set(old.map(\.identifier) + ["vm.call-reminder", "summary-123"])
        let diff = EventReminderPlanner.diff(planned: [], pendingIDs: pending)
        XCTAssertEqual(diff.remove, old.map(\.identifier))
        XCTAssertTrue(diff.add.isEmpty)
    }

    func testLeadChangeReconciles() {
        let ev = event(start: now.addingTimeInterval(3600))
        let three = EventReminderPlanner.plan(events: [ev], now: now, leadMinutes: 3, atStart: false)
        let ten = EventReminderPlanner.plan(events: [ev], now: now, leadMinutes: 10, atStart: false)
        XCTAssertNotEqual(three.first?.identifier, ten.first?.identifier)
        let diff = EventReminderPlanner.diff(planned: ten, pendingIDs: Set(three.map(\.identifier)))
        XCTAssertEqual(diff.add.count, 1)
        XCTAssertEqual(diff.remove.count, 1)
    }

    func testUnchangedPlanIsNoOp() {
        let ev = event(start: now.addingTimeInterval(600), link: meetLink)
        let plan = EventReminderPlanner.plan(events: [ev], now: now, leadMinutes: 5, atStart: true)
        let diff = EventReminderPlanner.diff(planned: plan, pendingIDs: Set(plan.map(\.identifier)))
        XCTAssertTrue(diff.add.isEmpty)
        XCTAssertTrue(diff.remove.isEmpty)
    }

    func testIdentifierFragmentMatchesEventIdentifiers() {
        let ev = event(start: now.addingTimeInterval(600), link: meetLink)
        let plan = EventReminderPlanner.plan(events: [ev], now: now, leadMinutes: 5, atStart: true)
        let fragment = EventReminderPlanner.identifierFragment(for: ev)
        XCTAssertTrue(plan.allSatisfy { $0.identifier.contains(fragment) })
    }
}
