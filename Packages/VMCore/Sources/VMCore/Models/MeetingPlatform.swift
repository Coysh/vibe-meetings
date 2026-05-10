import Foundation

/// Source platform a meeting was conducted on. Detected from the calendar
/// event for live recordings; nil for fully manual or imported meetings.
public enum MeetingPlatform: String, Codable, Sendable, CaseIterable {
    case teams
    case other
}
