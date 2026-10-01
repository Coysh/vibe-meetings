import Foundation

/// A calendar reminder notification that should be pending right now.
public struct PlannedReminder: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// N minutes before the event starts.
        case lead(minutes: Int)
        /// At the event's start time (online meetings only).
        case atStart
    }

    public let identifier: String
    public let kind: Kind
    public let event: CalendarEvent
    public let fireDate: Date
}

/// Pure planning for pre-meeting reminders.
///
/// Every poll the app computes the reminders that *should* be pending and
/// diffs them against what the notification centre actually has. The
/// identifier encodes the event, its title, its start time and the lead
/// time, so moving, renaming or cancelling an event — or changing the lead
/// time in Settings — naturally shows up as "remove the old, add the new".
public enum EventReminderPlanner {
    public static let identifierPrefix = "vm.event."

    public static func plan(
        events: [CalendarEvent],
        now: Date,
        leadMinutes: Int?,
        atStart: Bool
    ) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        for event in events where event.startDate > now {
            if let leadMinutes, leadMinutes > 0 {
                let fire = event.startDate.addingTimeInterval(-Double(leadMinutes) * 60)
                if fire > now {
                    let kind = PlannedReminder.Kind.lead(minutes: leadMinutes)
                    result.append(PlannedReminder(
                        identifier: identifier(kind: kind, event: event),
                        kind: kind, event: event, fireDate: fire
                    ))
                }
            }
            if atStart, event.hasMeetingLink {
                result.append(PlannedReminder(
                    identifier: identifier(kind: .atStart, event: event),
                    kind: .atStart, event: event, fireDate: event.startDate
                ))
            }
        }
        return result
    }

    public static func identifier(kind: PlannedReminder.Kind, event: CalendarEvent) -> String {
        let tag: String
        switch kind {
        case .lead(let minutes): tag = "lead\(minutes)"
        case .atStart: tag = "start"
        }
        let hash = djb2Hex("\(event.id)|\(event.title)")
        let epoch = Int(event.startDate.timeIntervalSince1970)
        return "\(identifierPrefix)\(tag).\(hash).\(epoch)"
    }

    /// Identifiers belonging to one event, regardless of kind — used to
    /// withdraw an event's reminders once it's being recorded.
    public static func identifierFragment(for event: CalendarEvent) -> String {
        ".\(djb2Hex("\(event.id)|\(event.title)"))."
    }

    /// What to add and what to remove so pending requests match `planned`.
    /// `pendingIDs` may contain unrelated identifiers; only ours are removed.
    public static func diff(
        planned: [PlannedReminder],
        pendingIDs: Set<String>
    ) -> (add: [PlannedReminder], remove: [String]) {
        let plannedIDs = Set(planned.map(\.identifier))
        let add = planned.filter { !pendingIDs.contains($0.identifier) }
        let remove = pendingIDs
            .filter { $0.hasPrefix(identifierPrefix) && !plannedIDs.contains($0) }
            .sorted()
        return (add, remove)
    }

    private static func djb2Hex(_ s: String) -> String {
        var hash: UInt64 = 5381
        for byte in s.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
