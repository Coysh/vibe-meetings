import AppKit
import Foundation
import UserNotifications
import VMCalendar
import VMCore

/// Single owner of the app's system notifications: permission, categories,
/// identifiers, and one `post…` helper per notification type.
@MainActor
final class NotificationManager {
    // MARK: - Identifiers

    enum Category {
        static let callDetected = "CALL_DETECTED"
        static let eventReminder = "EVENT_REMINDER"
        static let eventReminderWithLink = "EVENT_REMINDER_LINK"
        static let eventStarting = "EVENT_STARTING"
        static let meetingEnd = "MEETING_END"
        static let recordingStatus = "RECORDING_STATUS"
        static let summaryReady = "SUMMARY_READY"

        // Registered so notifications delivered by 1.6.x keep working buttons.
        static let legacyDetected = "MEETING_DETECTED"
        static let legacyReminder = "MEETING_REMINDER"
        static let legacyReminderTeams = "MEETING_REMINDER_TEAMS"

        /// Categories that nag about recording and are pointless while recording.
        static let recordingNags: Set<String> = [
            callDetected, eventReminder, eventReminderWithLink, eventStarting,
            legacyDetected, legacyReminder, legacyReminderTeams,
        ]
    }

    enum Action {
        static let record = "RECORD"
        static let snooze = "SNOOZE_10"
        static let notAMeeting = "NOT_MEETING"
        static let recordEvent = "RECORD_EVENT"
        static let joinAndRecord = "JOIN_AND_RECORD"
        static let stopRecording = "STOP_RECORDING"
        static let keepRecording = "KEEP_RECORDING"

        static let legacyStartRecording = "START_RECORDING"
        static let legacyStartListening = "START_LISTENING"
    }

    enum Key {
        static let sessionID = "sessionID"
        static let appName = "appName"
        static let eventID = "eventID"
        static let joinURL = "joinURL"
        static let meetingID = "meetingID"
        static let legacyTeamsURL = "teamsURL"
    }

    enum ID {
        static let callReminderPrefix = "vm.call-reminder"
        static let meetingEnd = "vm.meeting-end"
        static let micSilence = "vm.mic-silence"
        static let recordingStatusPrefix = "vm.recording-status."
        static let summaryPrefix = "vm.summary."
        static let legacyDetected = "meeting-detected"
        static let legacyReminderPrefix = "meeting-reminder-"
    }

    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool?
    /// Time-sensitive delivery needs an entitlement this (ad-hoc signed)
    /// build may not have; only request it when the system says it's on.
    private var timeSensitiveAvailable = false
    /// Delivered call-reminder identifiers, so each repeat can replace the
    /// previous one (a fresh identifier always re-alerts; re-using one may
    /// update silently).
    private var deliveredCallReminderIDs: Set<String> = []

    // MARK: - Setup

    static func registerCategories() {
        func action(_ id: String, _ title: String, _ options: UNNotificationActionOptions = []) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: options)
        }
        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        }

        // No `.foreground`: Record / Join & Record start in the background
        // without pulling the app window in front of the call.
        let record = action(Action.record, "Record")
        let snooze = action(Action.snooze, "Snooze 10 min")
        let notMeeting = action(Action.notAMeeting, "Not a meeting", .destructive)
        let recordEvent = action(Action.recordEvent, "Record")
        let join = action(Action.joinAndRecord, "Join & Record")
        let stop = action(Action.stopRecording, "Stop Recording", .destructive)
        let keep = action(Action.keepRecording, "Keep Recording")

        let legacyStart = action(Action.legacyStartRecording, "Start Recording")
        let legacyListen = action(Action.legacyStartListening, "Start Listening")

        UNUserNotificationCenter.current().setNotificationCategories([
            category(Category.callDetected, [record, snooze, notMeeting]),
            category(Category.eventReminder, [recordEvent]),
            category(Category.eventReminderWithLink, [join, recordEvent]),
            category(Category.eventStarting, [join, recordEvent]),
            category(Category.meetingEnd, [stop, keep]),
            category(Category.recordingStatus, []),
            category(Category.summaryReady, []),
            category(Category.legacyDetected, [legacyStart]),
            category(Category.legacyReminder, [legacyListen]),
            category(Category.legacyReminderTeams, [join, legacyListen]),
        ])
    }

    /// Requests permission the first time; afterwards returns the cached answer
    /// (refreshed from system settings, since the user can change it there).
    @discardableResult
    func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        timeSensitiveAvailable = settings.timeSensitiveSetting == .enabled
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            authorized = false
        }
        return authorized ?? false
    }

    func notificationSettings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    // MARK: - Call reminders

    func postCallReminder(
        session: CallSession,
        attempt: Int,
        eventTitle: String?,
        eventID: String?,
        now: Date = Date()
    ) async {
        let app = session.client.appName
        let content = UNMutableNotificationContent()
        if attempt == 0 {
            content.title = app.map { "\($0) call detected — not recording" } ?? "Call detected — not recording"
            content.body = eventTitle.map { "Record “\($0)”? Press Record to start instantly." }
                ?? "Press Record to start recording this call."
        } else {
            let minutes = max(1, Int(now.timeIntervalSince(session.startedAt) / 60))
            content.title = "Still not recording"
            let what = eventTitle.map { "“\($0)”" } ?? app.map { "your \($0) call" } ?? "your call"
            content.body = "You're \(minutes) min into \(what). Record now?"
        }
        content.sound = .default
        content.interruptionLevel = urgentLevel
        content.threadIdentifier = "calls"
        content.categoryIdentifier = Category.callDetected
        var info: [String: String] = [Key.sessionID: session.id.uuidString]
        info[Key.appName] = app
        info[Key.eventID] = eventID
        content.userInfo = info

        let identifier = "\(ID.callReminderPrefix).\(session.id.uuidString).\(attempt)"
        removeCallReminder()
        if await add(identifier: identifier, content: content) {
            deliveredCallReminderIDs.insert(identifier)
        }
    }

    /// Withdraw the current call reminder (recording started, snoozed, call ended…).
    func removeCallReminder() {
        var ids = Array(deliveredCallReminderIDs)
        ids.append(ID.legacyDetected)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        deliveredCallReminderIDs.removeAll()
    }

    /// Posts a sample call reminder so the user can try the buttons.
    func postTestCallReminder() async {
        let session = CallSession(
            client: CallClient(appID: "test", appName: "Test", kind: .call),
            startedAt: Date(),
            reminder: .pending(attempt: 0, nextAt: Date())
        )
        await postCallReminder(session: session, attempt: 0, eventTitle: "Test meeting", eventID: nil)
    }

    // MARK: - Calendar reminders

    func eventReminderRequest(for reminder: PlannedReminder) -> UNNotificationRequest {
        let event = reminder.event
        let content = UNMutableNotificationContent()
        content.title = event.title
        switch reminder.kind {
        case .lead(let minutes):
            content.body = "Starts in \(minutes) minute\(minutes == 1 ? "" : "s")"
                + (event.meetingLink.map { " on \($0.platform.displayName)" } ?? "")
                + " — record it?"
            content.categoryIdentifier = event.hasMeetingLink ? Category.eventReminderWithLink : Category.eventReminder
            content.interruptionLevel = .active
        case .atStart:
            content.body = "Starting now"
                + (event.meetingLink.map { " on \($0.platform.displayName)" } ?? "")
                + " — you're not recording yet."
            content.categoryIdentifier = Category.eventStarting
            content.interruptionLevel = urgentLevel
        }
        content.sound = .default
        content.threadIdentifier = "events"
        var info: [String: String] = [Key.eventID: event.id]
        info[Key.joinURL] = event.meetingLink?.url.absoluteString
        content.userInfo = info

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
    }

    func pendingRequestIDs() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    func schedule(_ request: UNNotificationRequest) async {
        guard await ensureAuthorized() else { return }
        try? await center.add(request)
    }

    func removePending(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Remove delivered + pending notifications whose identifier satisfies `predicate`.
    func removeAll(where predicate: @escaping @Sendable (String) -> Bool) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter(predicate)
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter(predicate)
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    // MARK: - Recording lifecycle

    func postMeetingEndSuggestion(reason: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Meeting may have ended"
        content.body = "\(reason). Stop recording?"
        content.sound = .default
        content.categoryIdentifier = Category.meetingEnd
        await add(identifier: ID.meetingEnd, content: content)
    }

    func removeMeetingEndSuggestion() {
        center.removeDeliveredNotifications(withIdentifiers: [ID.meetingEnd])
    }

    func postRecordingSaved(meetingID: UUID, title: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording saved"
        content.body = "“\(title)” — click to review and tag it. The summary is being generated."
        content.categoryIdentifier = Category.recordingStatus
        content.userInfo = [Key.meetingID: meetingID.uuidString]
        await add(identifier: ID.recordingStatusPrefix + meetingID.uuidString, content: content)
    }

    func postRecordingStartFailed(_ message: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't start recording"
        content.body = message
        content.sound = .default
        content.interruptionLevel = urgentLevel
        content.categoryIdentifier = Category.recordingStatus
        await add(identifier: ID.recordingStatusPrefix + "failed", content: content)
    }

    func postMicSilence() async {
        let content = UNMutableNotificationContent()
        content.title = "No Microphone Input"
        content.body = "Your microphone doesn't seem to be picking up any audio. Check it isn't muted or that the right input device is selected."
        content.sound = .default
        content.interruptionLevel = urgentLevel
        await add(identifier: ID.micSilence, content: content)
    }

    func postSummaryReady(meetingID: UUID, title: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Summary Ready"
        content.body = "Summary for “\(title)” is complete."
        content.sound = .default
        content.categoryIdentifier = Category.summaryReady
        content.userInfo = [Key.meetingID: meetingID.uuidString]
        await add(identifier: ID.summaryPrefix + meetingID.uuidString, content: content)
    }

    func postTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "vibe-meetings"
        content.body = "Notifications are working! You'll see alerts for meetings and summaries."
        content.sound = .default
        await add(identifier: "vm.test.\(UUID().uuidString)", content: content)
    }

    // MARK: - System Settings

    /// Opens System Settings → Notifications, on this app's page where possible.
    static func openSystemNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.vibe.meetings"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Private

    /// Breaks through Focus when the app is allowed to; otherwise a normal alert.
    private var urgentLevel: UNNotificationInterruptionLevel {
        timeSensitiveAvailable ? .timeSensitive : .active
    }

    @discardableResult
    private func add(identifier: String, content: UNMutableNotificationContent) async -> Bool {
        guard await ensureAuthorized() else { return false }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            print("[Notifications] failed to post \(identifier): \(error)")
            return false
        }
    }
}
