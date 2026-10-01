import Foundation
import VMCore

/// Picks the calendar event a detected call most likely belongs to.
public enum CurrentEventMatcher {
    /// - Parameters:
    ///   - earlyJoin: how long before its start an event still counts (people
    ///     join a few minutes early).
    ///   - platformHint: the platform of the app holding the mic; an event
    ///     whose join link matches it wins over overlapping events.
    public static func bestMatch(
        events: [CalendarEvent],
        now: Date,
        platformHint: MeetingPlatform? = nil,
        earlyJoin: TimeInterval = 10 * 60
    ) -> CalendarEvent? {
        let candidates = events.filter {
            $0.startDate.addingTimeInterval(-earlyJoin) <= now && now < $0.endDate
        }
        return candidates.min { a, b in
            let aMatch = platformHint != nil && a.meetingLink?.platform == platformHint
            let bMatch = platformHint != nil && b.meetingLink?.platform == platformHint
            if aMatch != bMatch { return aMatch }
            if a.hasMeetingLink != b.hasMeetingLink { return a.hasMeetingLink }
            return abs(a.startDate.timeIntervalSince(now)) < abs(b.startDate.timeIntervalSince(now))
        }
    }
}
