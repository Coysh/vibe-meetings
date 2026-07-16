import AppKit
import Foundation
import Observation
import UserNotifications
import VMCalendar
import VMCore

/// Detects when a meeting has likely ended by combining multiple signals:
/// - Calendar scheduled end time
/// - Extended audio silence (both mic and system audio)
/// - Meeting app (Teams, Zoom) no longer in a call
///
/// Publishes a `shouldSuggestEnd` flag and a human-readable `reason`.
@Observable
@MainActor
final class MeetingEndDetector {

    // MARK: - Published state

    var shouldSuggestEnd = false
    var endReason: String = ""

    // MARK: - Configuration (persisted)

    /// Whether auto-end detection is enabled at all.
    var autoEndEnabled: Bool {
        didSet { UserDefaults.standard.set(autoEndEnabled, forKey: Self.enabledKey) }
    }

    /// Seconds of silence before suggesting the meeting has ended.
    var silenceThresholdSeconds: TimeInterval {
        didSet { UserDefaults.standard.set(silenceThresholdSeconds, forKey: Self.silenceKey) }
    }

    /// dBFS level below which audio is considered "silence".
    /// -50 dBFS is very quiet; normal speech is around -20 to -30 dBFS.
    var silenceFloorDBFS: Float {
        didSet { UserDefaults.standard.set(Double(silenceFloorDBFS), forKey: Self.floorKey) }
    }

    /// Whether to monitor meeting app processes (Teams, Zoom, etc.).
    var appMonitoringEnabled: Bool {
        didSet { UserDefaults.standard.set(appMonitoringEnabled, forKey: Self.appMonKey) }
    }

    /// Whether to pop up a system notification if the microphone appears to be
    /// picking up no audio at all (wrong input device, muted, permission issue, etc.).
    var micSilenceNotificationEnabled: Bool {
        didSet { UserDefaults.standard.set(micSilenceNotificationEnabled, forKey: Self.micNotifKey) }
    }

    /// Seconds of continuous mic silence before we warn the user the mic
    /// doesn't seem to be picking anything up. Deliberately shorter than
    /// `silenceThresholdSeconds` — this isn't "the meeting probably ended",
    /// it's "your mic looks broken/muted right now".
    var micSilenceWarningSeconds: TimeInterval {
        didSet { UserDefaults.standard.set(micSilenceWarningSeconds, forKey: Self.micSilenceSecondsKey) }
    }

    // MARK: - Internal state

    /// Timestamp when both channels went below the silence floor.
    /// Reset whenever either channel rises above the floor.
    private var silenceStartedAt: Date?

    /// Timestamp when the mic channel alone went below the silence floor.
    /// Tracked independently of `silenceStartedAt` so a dead mic gets flagged
    /// even while system audio (other participants) is still coming through.
    private var micSilenceStartedAt: Date?

    /// Whether we've already warned about mic silence this recording session.
    /// Reset on `recordingDidStart`/`recordingDidStop` so we don't spam notifications.
    private var micSilenceNotified = false

    /// Whether the meeting app was detected as running when recording started.
    /// We only trigger app-exit detection if the app was running at start.
    private var meetingAppWasRunning = false

    /// The bundle IDs of meeting apps to monitor.
    private static let meetingAppBundleIDs: Set<String> = [
        "com.microsoft.teams",           // Teams classic
        "com.microsoft.teams2",          // Teams new (work/school)
        "us.zoom.xos",                   // Zoom
        "us.zoom.videomeeting",          // Zoom alt
        "com.google.Chrome",             // Google Meet (runs in Chrome)
    ]

    /// Process names to check as fallback (for apps without stable bundle IDs).
    private static let meetingAppProcessNames: Set<String> = [
        "Microsoft Teams",
        "Microsoft Teams (work or school)",
        "Microsoft Teams classic",
        "zoom.us",
        "Zoom",
    ]

    private static let enabledKey = "VibeMeetings.AutoEndDetection.Enabled"
    private static let silenceKey = "VibeMeetings.AutoEndDetection.SilenceSeconds"
    private static let floorKey = "VibeMeetings.AutoEndDetection.SilenceFloorDBFS"
    private static let appMonKey = "VibeMeetings.AutoEndDetection.AppMonitoring"
    private static let micNotifKey = "VibeMeetings.AutoEndDetection.MicSilenceNotification"
    private static let micSilenceSecondsKey = "VibeMeetings.AutoEndDetection.MicSilenceSeconds"

    private var dismissed = false
    private var monitorTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        self.autoEndEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.silenceThresholdSeconds = defaults.object(forKey: Self.silenceKey) as? TimeInterval ?? 120
        self.silenceFloorDBFS = Float(defaults.object(forKey: Self.floorKey) as? Double ?? -50.0)
        self.appMonitoringEnabled = defaults.object(forKey: Self.appMonKey) as? Bool ?? true
        self.micSilenceNotificationEnabled = defaults.object(forKey: Self.micNotifKey) as? Bool ?? true
        self.micSilenceWarningSeconds = defaults.object(forKey: Self.micSilenceSecondsKey) as? TimeInterval ?? 30
    }

    // MARK: - Lifecycle

    /// Call when recording starts. Snapshots the meeting app state and begins monitoring.
    func recordingDidStart(event: CalendarEvent?) {
        shouldSuggestEnd = false
        endReason = ""
        silenceStartedAt = nil
        micSilenceStartedAt = nil
        micSilenceNotified = false
        dismissed = false

        // Snapshot: is a meeting app currently running?
        meetingAppWasRunning = isMeetingAppRunning()

        // Start a periodic monitor for app exit detection.
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.checkMeetingAppStatus()
            }
        }
    }

    /// Call when recording stops.
    func recordingDidStop() {
        shouldSuggestEnd = false
        endReason = ""
        silenceStartedAt = nil
        micSilenceStartedAt = nil
        micSilenceNotified = false
        dismissed = false
        meetingAppWasRunning = false
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Call when the user dismisses the suggestion.
    func dismiss() {
        dismissed = true
        shouldSuggestEnd = false
        endReason = ""
    }

    // MARK: - Signal: Audio levels

    /// Called frequently with the latest audio level snapshot.
    /// Tracks how long both channels have been below the silence floor.
    func updateLevels(mic: Float, system: Float) {
        checkMicSilence(mic: mic)

        guard autoEndEnabled, !dismissed else { return }

        let bothSilent = mic < silenceFloorDBFS && system < silenceFloorDBFS

        if bothSilent {
            if silenceStartedAt == nil {
                silenceStartedAt = Date()
            }
            let silenceDuration = Date().timeIntervalSince(silenceStartedAt!)
            if silenceDuration >= silenceThresholdSeconds {
                let minutes = Int(silenceDuration / 60)
                suggest(reason: "No audio detected for \(minutes > 0 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "a while")")
            }
        } else {
            // Audio resumed — reset silence timer.
            silenceStartedAt = nil
        }
    }

    /// Tracks mic-only silence (independent of system audio) and pops a system
    /// notification once if the mic looks dead for `micSilenceWarningSeconds` —
    /// this catches a muted/wrong-device mic even while the rest of the call
    /// is audible via system audio, which `updateLevels`'s combined check would miss.
    private func checkMicSilence(mic: Float) {
        guard micSilenceNotificationEnabled, !micSilenceNotified else { return }

        if mic < silenceFloorDBFS {
            if micSilenceStartedAt == nil {
                micSilenceStartedAt = Date()
            }
            if Date().timeIntervalSince(micSilenceStartedAt!) >= micSilenceWarningSeconds {
                micSilenceNotified = true
                Task { await self.postMicSilenceNotification() }
            }
        } else {
            micSilenceStartedAt = nil
        }
    }

    private func postMicSilenceNotification() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "No Microphone Input"
        content.body = "Your microphone doesn't seem to be picking up any audio. Check it isn't muted or that the right input device is selected."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "mic-silence-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )
        try? await center.add(request)
    }

    // MARK: - Signal: Calendar end time

    /// Called periodically with the linked calendar event.
    func checkCalendarEnd(event: CalendarEvent?) {
        guard autoEndEnabled, !dismissed else { return }
        guard let event else { return }

        if Date() > event.endDate {
            suggest(reason: "Meeting has passed its scheduled end time")
        }
    }

    // MARK: - Signal: Meeting app process

    /// Checks whether the meeting app that was running at recording start
    /// is still running. If it's gone, the call likely ended.
    private func checkMeetingAppStatus() {
        guard autoEndEnabled, appMonitoringEnabled, !dismissed else { return }
        guard meetingAppWasRunning else { return }

        if !isMeetingAppRunning() {
            suggest(reason: "Meeting app appears to have ended the call")
        }
    }

    /// Returns true if any known meeting app is currently running.
    private func isMeetingAppRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications

        // Check by bundle ID.
        for app in runningApps {
            if let bundleID = app.bundleIdentifier,
               Self.meetingAppBundleIDs.contains(bundleID),
               !app.isTerminated {
                return true
            }
        }

        // Fallback: check by process name.
        for app in runningApps {
            if let name = app.localizedName,
               Self.meetingAppProcessNames.contains(name),
               !app.isTerminated {
                return true
            }
        }

        return false
    }

    // MARK: - Private

    private func suggest(reason: String) {
        guard !shouldSuggestEnd else { return } // Don't overwrite an existing suggestion.
        shouldSuggestEnd = true
        endReason = reason
    }
}
