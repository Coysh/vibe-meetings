import Foundation
import VMCalendar

/// Keeps pre-meeting reminder notifications in sync with the calendar.
///
/// Rather than scheduling once and forgetting (which left moved or cancelled
/// events firing at their old time), every pass computes the reminders that
/// *should* be pending and adds/removes the difference.
@MainActor
final class EventReminderScheduler {
    private let calendar: any CalendarService
    private let notifications: NotificationManager

    private var leadMinutesProvider: () -> Int? = { 3 }
    private var atStartProvider: () -> Bool = { true }

    private var task: Task<Void, Never>?
    private var cleanedLegacy = false
    private var reconciling = false
    /// Events being recorded: their remaining reminders are withdrawn and not re-added.
    private var suppressedEventIDs: Set<String> = []

    init(calendar: any CalendarService, notifications: NotificationManager) {
        self.calendar = calendar
        self.notifications = notifications
    }

    func setProviders(
        leadMinutes: @escaping () -> Int?,
        atStart: @escaping () -> Bool
    ) {
        leadMinutesProvider = leadMinutes
        atStartProvider = atStart
    }

    /// Polls every 30 s. Calendar edits are also forwarded via `setNeedsReconcile`
    /// (the calendar's change stream has a single consumer, BannerCoordinator).
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Settings or the calendar changed — re-plan now rather than on the next pass.
    func setNeedsReconcile() {
        Task { await reconcile() }
    }

    /// A recording started for `eventID`: drop its remaining reminders (e.g.
    /// the "starting now" one when you hit record a couple of minutes early).
    func recordingStarted(eventID: String?) {
        guard let eventID else { return }
        suppressedEventIDs.insert(eventID)
        Task { await reconcile() }
    }

    func reconcile() async {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }

        if !cleanedLegacy {
            cleanedLegacy = true
            // Requests scheduled by 1.6.x, which never updated them.
            await notifications.removeAll { $0.hasPrefix(NotificationManager.ID.legacyReminderPrefix) }
        }

        let now = Date()
        let events = await calendar.upcomingEvents(within: 2 * 60 * 60)
            .filter { !suppressedEventIDs.contains($0.id) }
        let planned: [PlannedReminder]
        if CalendarPreferences.shared.bannerEnabled {
            planned = EventReminderPlanner.plan(
                events: events,
                now: now,
                leadMinutes: leadMinutesProvider(),
                atStart: atStartProvider()
            )
        } else {
            planned = []
        }

        let pending = await notifications.pendingRequestIDs()
        let diff = EventReminderPlanner.diff(planned: planned, pendingIDs: pending)
        notifications.removePending(diff.remove)
        for reminder in diff.add {
            await notifications.schedule(notifications.eventReminderRequest(for: reminder))
        }

        // Forget suppressions for events that are long gone.
        if !suppressedEventIDs.isEmpty {
            let live = Set(await calendar.upcomingEvents(within: 24 * 60 * 60).map(\.id))
            suppressedEventIDs.formIntersection(live)
        }
    }
}
