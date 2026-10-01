import Foundation

/// When to (re)send the "you're in a call and not recording" reminder.
///
/// Expressed as gaps between consecutive reminders rather than absolute
/// offsets from the call start, so a snooze simply resumes the cadence from
/// wherever it left off instead of firing a burst of overdue reminders.
public struct ReminderSchedule: Sendable, Equatable {
    /// Offsets from the first reminder for the opening attempts.
    public var initialOffsets: [TimeInterval]
    /// Gap between reminders once `initialOffsets` is exhausted; `nil` stops.
    public var repeatInterval: TimeInterval?

    public init(initialOffsets: [TimeInterval], repeatInterval: TimeInterval?) {
        precondition(!initialOffsets.isEmpty, "a schedule needs at least one reminder")
        self.initialOffsets = initialOffsets
        self.repeatInterval = repeatInterval
    }

    /// Now, +2 min, +5 min, then every 5 min.
    public static let escalating = ReminderSchedule(initialOffsets: [0, 120, 300], repeatInterval: 300)

    /// A single reminder per call.
    public static let once = ReminderSchedule(initialOffsets: [0], repeatInterval: nil)

    /// Offset of attempt `n` (0-based) from the first reminder, or `nil` if
    /// the schedule never sends that attempt.
    public func offset(forAttempt n: Int) -> TimeInterval? {
        guard n >= 0 else { return nil }
        if n < initialOffsets.count { return initialOffsets[n] }
        guard let repeatInterval, let last = initialOffsets.last else { return nil }
        return last + Double(n - initialOffsets.count + 1) * repeatInterval
    }

    /// Delay between sending attempt `n` and attempt `n + 1`, or `nil` if
    /// attempt `n` is the last one.
    public func gap(afterAttempt n: Int) -> TimeInterval? {
        guard let current = offset(forAttempt: n), let next = offset(forAttempt: n + 1) else { return nil }
        return next - current
    }
}
