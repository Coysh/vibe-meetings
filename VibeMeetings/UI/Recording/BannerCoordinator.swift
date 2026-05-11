import Foundation
import Observation
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

    /// "The meeting is past its scheduled end — stop recording?"
    var meetingEndSuggestion: Bool = false

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
    private var micDismissed = false

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

    func start() {
        stop()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.recompute()
                self?.recomputeMeetingEnd()
                try? await Task.sleep(for: .seconds(30))
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
    }

    func dismissMeetingEnd() {
        meetingEndSuggestion = false
    }

    /// Called when a recording starts — resets per-session state.
    func recordingDidStart() {
        micActiveSuggestion = false
        micDismissed = false
        meetingEndSuggestion = false
    }

    /// Called when a recording stops — resets per-session state.
    func recordingDidStop() {
        meetingEndSuggestion = false
        micDismissed = false
    }

    // MARK: - Calendar suggestion (existing)

    private func recompute() async {
        prune()

        guard CalendarPreferences.shared.bannerEnabled,
              !isRecordingProvider()
        else { currentSuggestion = nil; return }

        guard let ev = await calendar.currentOrNextEvent(),
              ev.hasTeamsURL,
              ev.startDate <= Date().addingTimeInterval(5 * 60),
              ev.endDate > Date(),
              dismissalExpiries[ev.id] == nil
        else { currentSuggestion = nil; return }

        currentSuggestion = ev
    }

    private func prune() {
        let now = Date()
        dismissalExpiries = dismissalExpiries.filter { $0.value > now }
    }

    // MARK: - Mic activity detection

    private func handleMicActivity(_ active: Bool) {
        if active && !isRecordingProvider() && !micDismissed {
            micActiveSuggestion = true
        } else if !active {
            // Mic went silent — clear the suggestion if not already acted on.
            micActiveSuggestion = false
        }
    }

    // MARK: - Meeting end detection

    private func recomputeMeetingEnd() {
        guard isRecordingProvider() else {
            meetingEndSuggestion = false
            return
        }

        guard let event = activeEventProvider() else { return }

        if Date() > event.endDate {
            meetingEndSuggestion = true
        }
    }
}
