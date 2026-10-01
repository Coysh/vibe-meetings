import XCTest
@testable import VMCore

final class CallSessionMachineTests: XCTestCase {
    private let zoom = CallClient(appID: "zoom", appName: "Zoom", kind: .call)
    private let chrome = CallClient(appID: "chrome", appName: "Google Chrome", kind: .browser)
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func reminders(_ effects: [CallEffect]) -> [Int] {
        effects.compactMap { if case .postReminder(_, let attempt) = $0 { attempt } else { nil } }
    }

    /// Drives ticks every `step` seconds from `from` to `to`, collecting the
    /// times (relative to t0) at which reminders were posted.
    private func reminderTimes(_ m: inout CallSessionMachine, from: TimeInterval, to: TimeInterval, step: TimeInterval = 1) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var t = from
        while t <= to {
            if !reminders(m.handle(.tick, now: at(t))).isEmpty { times.append(t) }
            t += step
        }
        return times
    }

    // MARK: - Debounce

    func testCallAppIsConfirmedAfterDebounceAndRemindsImmediately() {
        var m = CallSessionMachine()
        XCTAssertTrue(m.handle(.mic([zoom]), now: at(0)).isEmpty)
        XCTAssertTrue(m.handle(.tick, now: at(2)).isEmpty)
        let effects = m.handle(.tick, now: at(3))
        XCTAssertTrue(effects.contains { if case .sessionStarted = $0 { true } else { false } })
        XCTAssertEqual(reminders(effects), [0])
        XCTAssertNotNil(m.unrecordedSession)
    }

    func testShortMicBlipNeverStartsASession() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.mic([]), now: at(1))
        XCTAssertTrue(m.handle(.tick, now: at(10)).isEmpty)
        XCTAssertNil(m.currentSession)
        XCTAssertNil(m.nextDeadline)
    }

    func testBrowserUsesLongerDebounce() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([chrome]), now: at(0))
        XCTAssertTrue(m.handle(.tick, now: at(5)).isEmpty)
        XCTAssertEqual(reminders(m.handle(.tick, now: at(10))), [0])
    }

    func testCallAppPreferredOverBrowser() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([chrome, zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        XCTAssertEqual(m.currentSession?.client.appID, "zoom")
    }

    // MARK: - Escalation

    func testEscalatingScheduleTiming() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        let times = reminderTimes(&m, from: 1, to: 3 + 16 * 60)
        // Confirmed at 3s; then +2, +5, +10, +15 min.
        let expected: [TimeInterval] = [3, 123, 303, 603, 903]
        XCTAssertEqual(times, expected)
    }

    func testOnceScheduleGoesQuietButStaysUnrecorded() {
        var config = CallSessionMachine.Config()
        config.schedule = .once
        var m = CallSessionMachine(config: config)
        _ = m.handle(.mic([zoom]), now: at(0))
        let times = reminderTimes(&m, from: 1, to: 30 * 60, step: 10)
        XCTAssertEqual(times.count, 1)
        XCTAssertEqual(m.currentSession?.reminder, .quiet)
        XCTAssertNotNil(m.unrecordedSession, "overlay should still show an unrecorded call")
    }

    // MARK: - Mute / end grace

    func testMuteToggleWithinGraceKeepsSameSession() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        let id = m.currentSession?.id
        _ = m.handle(.mic([]), now: at(30))
        _ = m.handle(.tick, now: at(60))
        let effects = m.handle(.mic([zoom]), now: at(80))
        XCTAssertTrue(reminders(effects).isEmpty, "unmuting must not re-trigger the first reminder")
        XCTAssertEqual(m.currentSession?.id, id)
    }

    func testCallEndsAfterGrace() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        _ = m.handle(.mic([]), now: at(100))
        XCTAssertTrue(m.handle(.tick, now: at(159)).isEmpty)
        let effects = m.handle(.tick, now: at(160))
        XCTAssertTrue(effects.contains(.removeReminder))
        XCTAssertTrue(effects.contains { if case .sessionEnded(_, false) = $0 { true } else { false } })
        XCTAssertNil(m.currentSession)
    }

    // MARK: - User actions

    func testSnoozeSilencesThenResumes() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        let effects = m.handle(.snooze(sessionID: m.currentSession?.id), now: at(10))
        XCTAssertTrue(effects.contains(.removeReminder))
        XCTAssertNotNil(m.unrecordedSession, "snoozed call is still unrecorded")
        let times = reminderTimes(&m, from: 11, to: 10 + 600 + 130)
        // Resumes at the end of the snooze with attempt 1, then +3 min gap.
        XCTAssertEqual(times.first, 610)
        XCTAssertEqual(times.count, 1)
    }

    func testSnoozeWithStaleSessionIDIsIgnored() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        XCTAssertTrue(m.handle(.snooze(sessionID: UUID()), now: at(10)).isEmpty)
        if case .pending = m.currentSession?.reminder {} else { XCTFail("should still be pending") }
    }

    func testNotAMeetingSilencesForRestOfCall() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        XCTAssertTrue(m.handle(.notAMeeting(sessionID: nil), now: at(10)).contains(.removeReminder))
        XCTAssertNil(m.unrecordedSession)
        XCTAssertTrue(reminderTimes(&m, from: 11, to: 3600, step: 30).isEmpty)
    }

    func testNotAMeetingIsRememberedIfSameAppReturnsSoon() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        _ = m.handle(.notAMeeting(sessionID: nil), now: at(10))
        _ = m.handle(.mic([]), now: at(20))
        _ = m.handle(.tick, now: at(80))              // ended
        _ = m.handle(.mic([zoom]), now: at(200))
        XCTAssertTrue(reminders(m.handle(.tick, now: at(203))).isEmpty)
        XCTAssertEqual(m.currentSession?.reminder, .dismissed)
    }

    func testNewCallAfterResumeWindowRemindsAgain() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        _ = m.handle(.notAMeeting(sessionID: nil), now: at(10))
        _ = m.handle(.mic([]), now: at(20))
        _ = m.handle(.tick, now: at(80))
        _ = m.handle(.mic([zoom]), now: at(2000))
        XCTAssertEqual(reminders(m.handle(.tick, now: at(2003))), [0])
    }

    func testDifferentAppAfterDismissalRemindsAgain() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        _ = m.handle(.notAMeeting(sessionID: nil), now: at(10))
        _ = m.handle(.mic([]), now: at(20))
        _ = m.handle(.tick, now: at(80))
        _ = m.handle(.mic([CallClient(appID: "teams", appName: "Microsoft Teams", kind: .call)]), now: at(100))
        XCTAssertEqual(reminders(m.handle(.tick, now: at(103))), [0])
    }

    // MARK: - Recording

    func testRecordingStartedMidCallStopsReminders() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        XCTAssertTrue(m.handle(.recordingStarted, now: at(30)).contains(.removeReminder))
        XCTAssertNil(m.unrecordedSession)
        XCTAssertTrue(reminderTimes(&m, from: 31, to: 3600, step: 30).isEmpty)
    }

    func testCallStartingWhileAlreadyRecordingNeverReminds() {
        var m = CallSessionMachine(isRecording: true)
        _ = m.handle(.mic([zoom]), now: at(0))
        XCTAssertTrue(reminders(m.handle(.tick, now: at(3))).isEmpty)
        XCTAssertEqual(m.currentSession?.reminder, .recording)
    }

    func testDeliberateStopMidCallDoesNotRenag() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        _ = m.handle(.recordingStarted, now: at(30))
        _ = m.handle(.recordingStopped, now: at(600))
        XCTAssertEqual(m.currentSession?.reminder, .handled)
        XCTAssertTrue(reminderTimes(&m, from: 601, to: 3600, step: 30).isEmpty)
    }

    func testFailedRecordingResumesReminders() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        _ = m.handle(.recordingStarted, now: at(30))
        XCTAssertEqual(reminders(m.handle(.recordingFailed, now: at(40))), [0])
        XCTAssertNotNil(m.unrecordedSession)
    }

    func testSessionEndedReportsRecording() {
        var m = CallSessionMachine()
        _ = m.handle(.mic([zoom]), now: at(0))
        _ = m.handle(.tick, now: at(3))
        _ = m.handle(.recordingStarted, now: at(30))
        _ = m.handle(.mic([]), now: at(100))
        let effects = m.handle(.tick, now: at(160))
        XCTAssertTrue(effects.contains { if case .sessionEnded(_, true) = $0 { true } else { false } })
        XCTAssertFalse(effects.contains(.removeReminder))
    }

    // MARK: - Deadlines

    func testNextDeadlineTracksState() {
        var m = CallSessionMachine()
        XCTAssertNil(m.nextDeadline)
        _ = m.handle(.mic([zoom]), now: at(0))
        XCTAssertEqual(m.nextDeadline, at(3))
        _ = m.handle(.tick, now: at(3))
        XCTAssertEqual(m.nextDeadline, at(123))
        _ = m.handle(.mic([]), now: at(50))
        XCTAssertEqual(m.nextDeadline, at(110))
    }
}
