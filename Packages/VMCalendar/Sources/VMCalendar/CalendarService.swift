import Foundation
import EventKit
import VMCore

public protocol CalendarService: Sendable {
    func requestAccess() async -> EKAuthorizationStatus
    func authorizationStatus() -> EKAuthorizationStatus
    func enabledCalendars() async -> [CalendarSummary]
    func allCalendars() async -> [CalendarSummary]
    func setExcluded(_ excluded: Bool, for calendarID: String) async
    func isExcluded(_ calendarID: String) -> Bool
    func upcomingEvents(within: TimeInterval) async -> [CalendarEvent]
    func currentOrNextEvent() async -> CalendarEvent?
    var events: AsyncStream<[CalendarEvent]> { get }
}

/// Sendable summary of an `EKCalendar` for UI use without leaking EventKit.
public struct CalendarSummary: Sendable, Hashable, Identifiable {
    public let id: String        // EKCalendar.calendarIdentifier
    public let title: String
    public let sourceTitle: String

    public init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

extension CalendarSummary {
    init(_ ek: EKCalendar) {
        self.init(
            id: ek.calendarIdentifier,
            title: ek.title,
            sourceTitle: ek.source.title
        )
    }
}

public actor EventKitCalendarService: CalendarService {
    private let store = EKEventStore()
    private let preferences: CalendarPreferences
    private nonisolated let eventsContinuation: AsyncStream<[CalendarEvent]>.Continuation
    public nonisolated let events: AsyncStream<[CalendarEvent]>

    // Both are written exactly once from `startObserving` (which runs inside
    // the actor) and read exactly once from `deinit`. Marked
    // `nonisolated(unsafe)` so the deinit — which is implicitly nonisolated
    // and cannot touch isolated stored properties of non-Sendable type —
    // can still tear down the NotificationCenter observer and the polling
    // task. The observer block also captures `[weak self]`, so even if this
    // teardown were skipped the residual callback would be a no-op once the
    // actor is deallocated.
    private nonisolated(unsafe) var observerToken: NSObjectProtocol?
    private nonisolated(unsafe) var pollingTask: Task<Void, Never>?

    public init(preferences: CalendarPreferences = .shared) {
        self.preferences = preferences

        var cont: AsyncStream<[CalendarEvent]>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventsContinuation = cont

        Task { await self.startObserving() }
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
        pollingTask?.cancel()
    }

    private func startObserving() {
        let token = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.emitUpcoming() }
        }
        self.observerToken = token

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.emitUpcoming()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func emitUpcoming() async {
        let evs = await upcomingEvents(within: 24 * 60 * 60)
        eventsContinuation.yield(evs)
    }

    // MARK: - Access

    public func requestAccess() async -> EKAuthorizationStatus {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // Denied / restricted — fall through to status read.
        }
        return EKEventStore.authorizationStatus(for: .event)
    }

    public nonisolated func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Calendars

    public func allCalendars() async -> [CalendarSummary] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event).map(CalendarSummary.init)
    }

    public func enabledCalendars() async -> [CalendarSummary] {
        await allCalendars().filter { !preferences.isExcluded($0.id) }
    }

    public func setExcluded(_ excluded: Bool, for calendarID: String) async {
        preferences.setExcluded(excluded, for: calendarID)
    }

    public nonisolated func isExcluded(_ calendarID: String) -> Bool {
        preferences.isExcluded(calendarID)
    }

    // MARK: - Events

    public func upcomingEvents(within window: TimeInterval) async -> [CalendarEvent] {
        guard isAuthorized else { return [] }
        let calendars = store.calendars(for: .event).filter { !preferences.isExcluded($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-15 * 60), // include the just-started case
            end: now.addingTimeInterval(window),
            calendars: calendars
        )
        let ek = store.events(matching: predicate)
        return ek
            .sorted { $0.startDate < $1.startDate }
            .map(CalendarEvent.init(from:))
    }

    public func currentOrNextEvent() async -> CalendarEvent? {
        let evs = await upcomingEvents(within: 12 * 60 * 60)
        let now = Date()
        return evs.first { $0.endDate > now }
    }

    private var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }
}
