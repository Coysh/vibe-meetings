import Foundation
import Observation
import VMCalendar

/// Decides when the "a Teams meeting is starting — start recording?" banner
/// should be visible. Polls every 30 s and reacts to `EKEventStoreChanged`.
///
/// Banner-worthy condition:
///   event.hasTeamsURL
///   && event.startDate <= now + 5 min
///   && event.endDate > now
///   && !isRecording
///   && !dismissedEventIDs.contains(event.id)
///   && CalendarPreferences.shared.bannerEnabled
@Observable
@MainActor
final class BannerCoordinator {
    var currentSuggestion: CalendarEvent?

    private let calendar: any CalendarService
    private var dismissalExpiries: [String: Date] = [:]
    private var pollingTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var isRecordingProvider: () -> Bool = { false }

    init(calendar: any CalendarService) {
        self.calendar = calendar
    }

    /// Caller injects a closure so the coordinator stays decoupled from
    /// `RecordingController`'s identity / lifecycle.
    func setIsRecordingProvider(_ provider: @escaping () -> Bool) {
        self.isRecordingProvider = provider
    }

    func start() {
        stop()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.recompute()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        let stream = calendar.events
        streamTask = Task { [weak self] in
            for await _ in stream {
                await self?.recompute()
            }
        }
    }

    func stop() {
        pollingTask?.cancel(); pollingTask = nil
        streamTask?.cancel(); streamTask = nil
    }

    func dismiss(_ event: CalendarEvent) {
        dismissalExpiries[event.id] = event.endDate
        currentSuggestion = nil
    }

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
}
