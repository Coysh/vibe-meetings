import AppKit
import Foundation
import Observation
import UserNotifications
import VMCalendar
import VMRecording

/// Decides when the "a Teams meeting is starting — start recording?" banner
/// should be visible. Polls every 30 s and reacts to `EKEventStoreChanged`.
///
/// Also monitors:
/// - Microphone activity (another app opens the mic while we're not recording)
/// - Calendar event end (the linked calendar event has ended but we're still recording)
@Observable
@MainActor
final class BannerCoordinator {
    // MARK: - Banner states

    /// "Teams meeting is starting — start recording?"
    var currentSuggestion: CalendarEvent?

    /// "Your microphone just became active — start recording?"
    var micActiveSuggestion: Bool = false

    /// Calendar event title to show in the mic banner, if a current event was found.
    var micEventTitle: String?

    /// Name of the app currently using the microphone (e.g., "Microsoft Teams").
    var micActiveAppName: String?

    /// "The meeting has likely ended — stop recording?"
    var meetingEndSuggestion: Bool = false

    /// Human-readable reason for the meeting end suggestion (e.g., "No audio for 2 minutes").
    var meetingEndReason: String = ""

    // MARK: - Dependencies

    private let calendar: any CalendarService
    private let micMonitor = MicrophoneActivityMonitor()

    private var dismissalExpiries: [String: Date] = [:]
    private var pollingTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var micMonitorTask: Task<Void, Never>?
    private var meetingEndTask: Task<Void, Never>?

    private var isRecordingProvider: () -> Bool = { false }
    private var activeEventProvider: () -> CalendarEvent? = { nil }
    private var notifyMeetingDetectedProvider: () -> Bool = { true }
    private var notifyPreMeetingReminderProvider: () -> Bool = { true }
    private var reminderMinutesProvider: () -> Int = { 3 }
    private var micDismissed = false
    private var meetingEndDetector: MeetingEndDetector?

    /// Prevents sending repeated system notifications for the same detected call.
    private var notificationPosted = false

    /// Event IDs for which we've already scheduled a pre-meeting reminder.
    private var scheduledReminderIDs: Set<String> = []

    /// Notification category and action identifiers.
    nonisolated static let meetingDetectedCategory = "MEETING_DETECTED"
    nonisolated static let startRecordingAction = "START_RECORDING"

    /// Pre-meeting reminder category and actions.
    nonisolated static let meetingReminderCategory = "MEETING_REMINDER"
    nonisolated static let startListeningAction = "START_LISTENING"
    nonisolated static let joinAndRecordAction = "JOIN_AND_RECORD"

    init(calendar: any CalendarService) {
        self.calendar = calendar
    }

    /// Caller injects a closure so the coordinator stays decoupled from
    /// `RecordingController`'s identity / lifecycle.
    func setIsRecordingProvider(_ provider: @escaping () -> Bool) {
        self.isRecordingProvider = provider
    }

    /// Inject a provider that returns the calendar event linked to the current
    /// recording, if any. Used for auto-end detection.
    func setActiveEventProvider(_ provider: @escaping () -> CalendarEvent?) {
        self.activeEventProvider = provider
    }

    /// Inject the meeting end detector for multi-signal end detection.
    func setMeetingEndDetector(_ detector: MeetingEndDetector) {
        self.meetingEndDetector = detector
    }

    /// Inject notification preference providers so the coordinator respects
    /// user settings without a direct dependency on AppEnvironment.
    func setNotificationProviders(
        meetingDetected: @escaping () -> Bool,
        preMeetingReminder: @escaping () -> Bool,
        reminderMinutes: @escaping () -> Int
    ) {
        self.notifyMeetingDetectedProvider = meetingDetected
        self.notifyPreMeetingReminderProvider = preMeetingReminder
        self.reminderMinutesProvider = reminderMinutes
    }

    func start() {
        stop()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.recompute()
                await self?.scheduleUpcomingReminders()
                self?.recomputeMeetingEnd()
                await self?.pollMeetingAppActivity()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        let stream = calendar.events
        streamTask = Task { [weak self] in
            for await _ in stream {
                await self?.recompute()
            }
        }

        // Start mic activity monitoring.
        micMonitor.start()
        let micStream = micMonitor.isActive
        micMonitorTask = Task { [weak self] in
            for await active in micStream {
                self?.handleMicActivity(active)
            }
        }
    }

    func stop() {
        pollingTask?.cancel(); pollingTask = nil
        streamTask?.cancel(); streamTask = nil
        micMonitorTask?.cancel(); micMonitorTask = nil
        meetingEndTask?.cancel(); meetingEndTask = nil
        micMonitor.stop()
    }

    func dismiss(_ event: CalendarEvent) {
        dismissalExpiries[event.id] = event.endDate
        currentSuggestion = nil
    }

    func dismissMicSuggestion() {
        micActiveSuggestion = false
        micDismissed = true
        notificationPosted = false
    }

    func dismissMeetingEnd() {
        meetingEndSuggestion = false
        meetingEndReason = ""
        meetingEndDetector?.dismiss()
    }

    /// Called when a recording starts — resets per-session state.
    func recordingDidStart() {
        micActiveSuggestion = false
        micDismissed = false
        meetingEndSuggestion = false
        notificationPosted = false
    }

    /// Called when a recording stops — resets per-session state.
    func recordingDidStop() {
        meetingEndSuggestion = false
        micDismissed = false
        notificationPosted = false
    }

    // MARK: - Calendar suggestion (existing)

    private func recompute() async {
        prune()

        guard CalendarPreferences.shared.bannerEnabled,
              !isRecordingProvider()
        else { currentSuggestion = nil; return }

        guard let ev = await calendar.currentOrNextEvent(),
              ev.startDate <= Date().addingTimeInterval(5 * 60),
              ev.endDate > Date(),
              dismissalExpiries[ev.id] == nil
        else { currentSuggestion = nil; return }

        // Show if the event has a Teams URL, or if a meeting app is currently running.
        if ev.hasTeamsURL || isMeetingAppRunning() {
            currentSuggestion = ev
        } else {
            currentSuggestion = nil
        }
    }

    /// Known meeting app bundle IDs mapped to display names.
    /// Only dedicated meeting apps — browsers are excluded because they run all day.
    private static let meetingApps: [String: String] = [
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "us.zoom.xos": "Zoom",
        "us.zoom.videomeeting": "Zoom",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
    ]

    /// Returns true if any known meeting app is currently running.
    private func isMeetingAppRunning() -> Bool {
        runningMeetingAppName() != nil
    }

    /// Returns the display name of the first running meeting app found, or nil.
    private func runningMeetingAppName() -> String? {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if let bid = app.bundleIdentifier,
               let name = Self.meetingApps[bid],
               !app.isTerminated {
                return name
            }
        }
        return nil
    }

    private func prune() {
        let now = Date()
        dismissalExpiries = dismissalExpiries.filter { $0.value > now }
    }

    // MARK: - Mic activity detection

    private func handleMicActivity(_ active: Bool) {
        if active && !isRecordingProvider() && !micDismissed {
            // Detect which app is using the mic.
            micActiveAppName = runningMeetingAppName()

            // Try to find a current calendar event to show its title.
            Task {
                var title: String?
                if let ev = await calendar.currentOrNextEvent(),
                   ev.startDate <= Date().addingTimeInterval(5 * 60),
                   ev.endDate > Date() {
                    title = ev.title
                }
                micEventTitle = title

                // Post system notification so user sees it even if window is hidden.
                if !notificationPosted {
                    notificationPosted = true
                    await postMeetingDetectedNotification(eventTitle: title, appName: micActiveAppName)
                }
            }
            micActiveSuggestion = true
        } else if !active {
            // Mic went silent. If a meeting app is still running, keep the
            // banner visible — the mic may toggle during a call (mute/unmute).
            // Only clear if no meeting app is running.
            if !isMeetingAppRunning() {
                micActiveSuggestion = false
                micEventTitle = nil
                micActiveAppName = nil
            }
        }
    }

    // MARK: - Meeting app polling

    /// Periodically checks whether a meeting app is running. Triggers when:
    /// 1. A meeting app is running during a calendar event window, OR
    /// 2. A meeting app is running AND the microphone is actively in use
    ///    (catches impromptu calls with no calendar event).
    private func pollMeetingAppActivity() async {
        guard !isRecordingProvider(), !micDismissed else { return }

        // Already showing a calendar-based suggestion or mic banner — skip.
        if currentSuggestion != nil || micActiveSuggestion { return }

        // Check if a meeting app is running.
        guard let appName = runningMeetingAppName() else {
            // Meeting app stopped — allow a fresh notification next time.
            notificationPosted = false
            return
        }

        // Check for a calendar event in progress or about to start.
        let ev: CalendarEvent?
        if let candidate = await calendar.currentOrNextEvent(),
           candidate.startDate <= Date().addingTimeInterval(5 * 60),
           candidate.endDate > Date() {
            ev = candidate
        } else {
            ev = nil
        }

        // If no calendar event, check if the mic is actively in use.
        // A meeting app running + mic active = strong signal of an actual call,
        // even without a calendar event (handles impromptu/ad-hoc calls).
        let micRunning = micMonitor.isMicCurrentlyRunning
        guard ev != nil || micRunning else {
            // Meeting app is open but no call evidence — don't spam.
            return
        }

        // A meeting app is running with call evidence — show the mic banner.
        micActiveAppName = appName
        micEventTitle = ev?.title
        micActiveSuggestion = true

        // Also post a system notification so the user sees it even if the app window is hidden.
        if !notificationPosted {
            notificationPosted = true
            await postMeetingDetectedNotification(eventTitle: ev?.title, appName: appName)
        }
    }

    // MARK: - Pre-meeting reminders

    /// Schedule reminder notifications for upcoming calendar events. Skips
    /// events we've already scheduled, events that have already started, and
    /// events starting more than 1 hour out.
    private func scheduleUpcomingReminders() async {
        guard notifyPreMeetingReminderProvider(),
              CalendarPreferences.shared.bannerEnabled else { return }
        let reminderLeadTime = TimeInterval(reminderMinutesProvider() * 60)
        let events = await calendar.upcomingEvents(within: 60 * 60)
        let now = Date()
        let center = UNUserNotificationCenter.current()

        for event in events {
            guard !scheduledReminderIDs.contains(event.id) else { continue }

            let fireDate = event.startDate.addingTimeInterval(-reminderLeadTime)
            // Only schedule if the fire date is in the future.
            guard fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = event.title
            let minutesUntil = Int(ceil(reminderLeadTime / 60))
            content.body = "Starting in \(minutesUntil) minute\(minutesUntil == 1 ? "" : "s")"
            content.sound = .default

            if event.hasTeamsURL {
                content.categoryIdentifier = Self.meetingReminderCategory + "_TEAMS"
                // Store the Teams URL so the action handler can open it.
                content.userInfo = ["teamsURL": event.teamsJoinURL!.absoluteString,
                                    "eventID": event.id]
            } else {
                content.categoryIdentifier = Self.meetingReminderCategory
                content.userInfo = ["eventID": event.id]
            }

            let interval = fireDate.timeIntervalSince(now)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 1), repeats: false)
            let request = UNNotificationRequest(
                identifier: "meeting-reminder-\(event.id)",
                content: content,
                trigger: trigger
            )

            try? await center.add(request)
            scheduledReminderIDs.insert(event.id)
        }
    }

    // MARK: - System notifications

    /// Register notification categories with action buttons.
    /// Call once at app launch.
    static func registerNotificationCategory() {
        let startAction = UNNotificationAction(
            identifier: startRecordingAction,
            title: "Start Recording",
            options: [.foreground]
        )
        let detectedCategory = UNNotificationCategory(
            identifier: meetingDetectedCategory,
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )

        // Pre-meeting reminder: "Start Listening" only (no Teams URL).
        let listenAction = UNNotificationAction(
            identifier: startListeningAction,
            title: "Start Listening",
            options: [.foreground]
        )
        let reminderCategory = UNNotificationCategory(
            identifier: meetingReminderCategory,
            actions: [listenAction],
            intentIdentifiers: [],
            options: []
        )

        // Pre-meeting reminder with Teams: "Join & Record" + "Start Listening".
        let joinAction = UNNotificationAction(
            identifier: joinAndRecordAction,
            title: "Join & Record",
            options: [.foreground]
        )
        let reminderTeamsCategory = UNNotificationCategory(
            identifier: meetingReminderCategory + "_TEAMS",
            actions: [joinAction, listenAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            detectedCategory, reminderCategory, reminderTeamsCategory,
        ])
    }

    /// Post a macOS system notification alerting the user that a meeting was detected.
    private func postMeetingDetectedNotification(eventTitle: String?, appName: String? = nil) async {
        guard notifyMeetingDetectedProvider() else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        if let title = eventTitle {
            content.title = "Meeting Detected"
            content.body = "\"\(title)\" — would you like to start recording?"
        } else if let app = appName {
            content.title = "Call Detected"
            content.body = "\(app) is using the microphone. Would you like to start recording?"
        } else {
            content.title = "Call Detected"
            content.body = "A meeting app is active. Would you like to start recording?"
        }
        content.sound = .default
        content.categoryIdentifier = Self.meetingDetectedCategory

        let request = UNNotificationRequest(
            identifier: "meeting-detected",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    // MARK: - Meeting end detection

    private func recomputeMeetingEnd() {
        guard isRecordingProvider() else {
            meetingEndSuggestion = false
            meetingEndReason = ""
            return
        }

        // Forward calendar event to the detector for time-based check.
        let event = activeEventProvider()
        meetingEndDetector?.checkCalendarEnd(event: event)

        // Mirror the detector's combined decision (silence + calendar + app exit).
        if let detector = meetingEndDetector, detector.shouldSuggestEnd {
            meetingEndSuggestion = true
            meetingEndReason = detector.endReason
        }
    }
}
