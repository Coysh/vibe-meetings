import AppKit
import Foundation
import Observation
import VMCalendar
import VMCore
import VMRecording

/// Call awareness: decides when to nudge the user to record.
///
/// - Watches which apps hold the microphone (on any input device) via
///   `ProcessMicActivityMonitor`, and feeds that into `CallSessionMachine`,
///   which debounces blips, tolerates mute toggles and runs the escalating
///   "you're in a call and not recording" reminder schedule.
/// - Drives the in-app banners (calendar suggestion, detected call, meeting
///   probably ended) and the state shown by the overlay and menu bar.
@Observable
@MainActor
final class BannerCoordinator {
    // MARK: - Published state

    /// "<event> is starting — start recording?" (calendar-driven banner).
    var currentSuggestion: CalendarEvent?

    /// The call in progress (recorded or not), if any.
    private(set) var currentCall: CallSession?

    /// The call in progress if it's unrecorded and the user hasn't opted out
    /// ("Not a meeting"). Drives the overlay, menu bar and in-app banner.
    private(set) var unrecordedCall: CallSession?

    /// Calendar event matching the current call, if any.
    private(set) var matchedEvent: CalendarEvent?

    /// "The meeting has likely ended — stop recording?"
    var meetingEndSuggestion: Bool = false

    /// Human-readable reason for the meeting end suggestion (e.g., "No audio for 2 minutes").
    var meetingEndReason: String = ""

    // In-app "call detected" banner (MicActiveBanner).
    var micActiveSuggestion: Bool { unrecordedCall != nil }
    var micEventTitle: String? { unrecordedCall == nil ? nil : matchedEvent?.title }
    var micActiveAppName: String? { unrecordedCall?.client.appName }

    var isCallSnoozed: Bool {
        if case .snoozed = unrecordedCall?.reminder { return true }
        return false
    }

    // MARK: - Dependencies

    private let calendar: any CalendarService
    private let notifications: NotificationManager
    private let micMonitor = ProcessMicActivityMonitor()
    private var machine = CallSessionMachine()

    private var dismissalExpiries: [String: Date] = [:]
    private var pollingTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var micMonitorTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var started = false

    /// Upcoming/in-progress events, refreshed every poll and on calendar changes.
    private(set) var cachedEvents: [CalendarEvent] = []

    private var isRecordingProvider: () -> Bool = { false }
    private var activeEventProvider: () -> CalendarEvent? = { nil }
    private var notifyMeetingDetectedProvider: () -> Bool = { true }
    private var escalatingProvider: () -> Bool = { true }
    private var detectBrowserCallsProvider: () -> Bool = { true }
    private var isMainWindowKeyProvider: () -> Bool = { false }
    private var onCalendarChanged: () -> Void = {}
    private var meetingEndDetector: MeetingEndDetector?

    init(calendar: any CalendarService, notifications: NotificationManager) {
        self.calendar = calendar
        self.notifications = notifications
    }

    // MARK: - Wiring

    /// Caller injects closures so the coordinator stays decoupled from
    /// `RecordingSessionService` / `AppEnvironment`.
    func configure(
        isRecording: @escaping () -> Bool,
        activeEvent: @escaping () -> CalendarEvent?,
        meetingEndDetector: MeetingEndDetector,
        notifyMeetingDetected: @escaping () -> Bool,
        escalatingReminders: @escaping () -> Bool,
        detectBrowserCalls: @escaping () -> Bool,
        isMainWindowKey: @escaping () -> Bool,
        onCalendarChanged: @escaping () -> Void
    ) {
        isRecordingProvider = isRecording
        activeEventProvider = activeEvent
        self.meetingEndDetector = meetingEndDetector
        notifyMeetingDetectedProvider = notifyMeetingDetected
        escalatingProvider = escalatingReminders
        detectBrowserCallsProvider = detectBrowserCalls
        isMainWindowKeyProvider = isMainWindowKey
        self.onCalendarChanged = onCalendarChanged
    }

    func start() {
        guard !started else { return }
        started = true

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshEvents()
                await self?.recomputeSuggestion()
                self?.recomputeMeetingEnd()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        let stream = calendar.events
        streamTask = Task { [weak self] in
            for await _ in stream {
                await self?.refreshEvents()
                await self?.recomputeSuggestion()
                self?.onCalendarChanged()
            }
        }

        micMonitor.start()
        let snapshots = micMonitor.snapshots
        micMonitorTask = Task { [weak self] in
            for await snapshot in snapshots {
                self?.handleMicSnapshot(snapshot)
            }
        }
    }

    // MARK: - User actions

    func dismiss(_ event: CalendarEvent) {
        dismissalExpiries[event.id] = event.endDate
        currentSuggestion = nil
    }

    /// "Not a meeting" — stop reminding for the rest of this call.
    func notAMeeting(sessionID: UUID? = nil) {
        feed(.notAMeeting(sessionID: sessionID))
    }

    /// Silence reminders for 10 minutes.
    func snooze(sessionID: UUID? = nil) {
        feed(.snooze(sessionID: sessionID))
    }

    /// In-app banner dismiss button.
    func dismissMicSuggestion() {
        notAMeeting()
    }

    func dismissMeetingEnd() {
        meetingEndSuggestion = false
        meetingEndReason = ""
        meetingEndDetector?.dismiss()
        notifications.removeMeetingEndSuggestion()
    }

    // MARK: - Recording lifecycle (called by RecordingSessionService)

    func recordingDidStart() {
        currentSuggestion = nil
        feed(.recordingStarted)
    }

    func recordingDidStop() {
        meetingEndSuggestion = false
        meetingEndReason = ""
        feed(.recordingStopped)
    }

    func recordingFailed() {
        feed(.recordingFailed)
    }

    /// Re-fetches events and returns the event to link a one-click
    /// recording to: the current call's match, else whatever is on the
    /// calendar right now.
    func bestCurrentEvent() async -> CalendarEvent? {
        await refreshEvents()
        return matchedEvent ?? CurrentEventMatcher.bestMatch(events: cachedEvents, now: Date())
    }

    /// An in-progress or imminent event with a join link (for "Join & Record").
    var joinableEvent: CalendarEvent? {
        let candidate = matchedEvent ?? CurrentEventMatcher.bestMatch(events: cachedEvents, now: Date())
        return candidate?.hasMeetingLink == true ? candidate : nil
    }

    // MARK: - Calendar suggestion

    private func refreshEvents() async {
        cachedEvents = await calendar.upcomingEvents(within: 12 * 60 * 60)
        updateMatchedEvent()
    }

    private func updateMatchedEvent() {
        guard let call = currentCall else { matchedEvent = nil; return }
        let hint = MeetingAppCatalog.app(withID: call.client.appID)?.platform
        matchedEvent = CurrentEventMatcher.bestMatch(events: cachedEvents, now: Date(), platformHint: hint)
    }

    private func recomputeSuggestion() async {
        prune()

        guard CalendarPreferences.shared.bannerEnabled,
              !isRecordingProvider()
        else { currentSuggestion = nil; return }

        let now = Date()
        guard let ev = cachedEvents.first(where: { $0.endDate > now }),
              ev.startDate <= now.addingTimeInterval(5 * 60),
              dismissalExpiries[ev.id] == nil
        else { currentSuggestion = nil; return }

        // Show if the event has a join link, or if a meeting app is currently running.
        currentSuggestion = (ev.hasMeetingLink || runningCallApp() != nil) ? ev : nil
    }

    private func runningCallApp() -> MeetingApp? {
        MeetingAppCatalog.runningCallApp(
            in: NSWorkspace.shared.runningApplications
                .filter { !$0.isTerminated }
                .map { (bundleID: $0.bundleIdentifier, name: $0.localizedName) }
        )
    }

    private func prune() {
        let now = Date()
        dismissalExpiries = dismissalExpiries.filter { $0.value > now }
    }

    // MARK: - Call detection

    private func handleMicSnapshot(_ snapshot: MicUsageSnapshot) {
        feed(.mic(classify(snapshot)))
    }

    /// Turns raw mic users into the clients call detection cares about.
    private func classify(_ snapshot: MicUsageSnapshot) -> [CallClient] {
        guard snapshot.processListAvailable else {
            // Fallback: device-level signal only. Our own recording also
            // keeps the device running, so ignore it while recording.
            guard snapshot.defaultDeviceRunningSomewhere, !isRecordingProvider() else { return [] }
            if let app = runningCallApp() {
                return [CallClient(appID: app.id, appName: app.displayName, kind: .call)]
            }
            return [CallClient(appID: "unknown", appName: nil, kind: .browser)]
        }

        let inCalendarEvent = CurrentEventMatcher.bestMatch(events: cachedEvents, now: Date(), earlyJoin: 5 * 60) != nil
        var clients: [CallClient] = []
        for mic in snapshot.clients {
            let app = MeetingAppCatalog.classify(bundleID: mic.bundleID, processName: mic.processName)
            switch app?.kind {
            case .ignored:
                continue
            case .call:
                clients.append(CallClient(appID: app!.id, appName: app!.displayName, kind: .call))
            case .browser:
                guard detectBrowserCallsProvider() else { continue }
                clients.append(CallClient(appID: app!.id, appName: app!.displayName, kind: .browser))
            case nil:
                // Unknown app using the mic: only a call if the calendar says
                // you're in a meeting right now.
                guard inCalendarEvent else { continue }
                let name = NSRunningApplication(processIdentifier: mic.pid)?.localizedName ?? mic.processName
                clients.append(CallClient(appID: mic.bundleID ?? mic.processName ?? "pid-\(mic.pid)", appName: name, kind: .browser))
            }
        }
        var seen = Set<String>()
        return clients.filter { seen.insert($0.appID).inserted }
    }

    private func feed(_ input: CallInput) {
        machine.config.schedule = escalatingProvider() ? .escalating : .once
        let effects = machine.handle(input, now: Date())
        let previousCallID = currentCall?.id
        currentCall = machine.currentSession
        unrecordedCall = machine.unrecordedSession
        if currentCall?.id != previousCallID { updateMatchedEvent() }
        for effect in effects { perform(effect) }
        scheduleTick()
    }

    private func perform(_ effect: CallEffect) {
        switch effect {
        case .sessionStarted(let session):
            print("[CallDetection] call started: \(session.client.appName ?? session.client.appID)")
            Task { await self.refreshEvents() }
        case .postReminder(let session, let attempt):
            guard notifyMeetingDetectedProvider() else { return }
            let event = matchedEvent
            Task {
                await notifications.postCallReminder(
                    session: session, attempt: attempt,
                    eventTitle: event?.title, eventID: event?.id
                )
            }
        case .removeReminder:
            notifications.removeCallReminder()
        case .sessionEnded(let session, let wasRecording):
            print("[CallDetection] call ended: \(session.client.appName ?? session.client.appID)")
            notifications.removeCallReminder()
            if wasRecording {
                meetingEndDetector?.callAppReleasedMic(appName: session.client.appName)
                recomputeMeetingEnd()
            }
        }
    }

    /// Wake up when the machine's next deadline (debounce, reminder, end
    /// grace) is due.
    private func scheduleTick() {
        tickTask?.cancel()
        guard let deadline = machine.nextDeadline else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.feed(.tick)
        }
    }

    // MARK: - Meeting end detection

    private func recomputeMeetingEnd() {
        guard isRecordingProvider() else {
            meetingEndSuggestion = false
            meetingEndReason = ""
            return
        }

        // Forward calendar event to the detector for time-based check.
        meetingEndDetector?.checkCalendarEnd(event: activeEventProvider())

        // Mirror the detector's combined decision (silence + calendar + app exit).
        if let detector = meetingEndDetector, detector.shouldSuggestEnd, !meetingEndSuggestion {
            meetingEndSuggestion = true
            meetingEndReason = detector.endReason
            // The in-app banner is invisible if the window isn't in front.
            if !isMainWindowKeyProvider() {
                let reason = detector.endReason
                Task { await notifications.postMeetingEndSuggestion(reason: reason) }
            }
        }
    }
}
