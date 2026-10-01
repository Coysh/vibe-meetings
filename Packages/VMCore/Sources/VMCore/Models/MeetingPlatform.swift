import Foundation

/// Source platform a meeting was conducted on. Detected from the calendar
/// event (join link) or the app holding the microphone for live recordings;
/// nil for fully manual or imported meetings.
public enum MeetingPlatform: String, Codable, Sendable, CaseIterable {
    case teams
    case zoom
    case googleMeet = "google-meet"
    case webex
    case other

    /// Decodes leniently: values written by a newer build that this build
    /// doesn't know about become `.other` instead of failing the whole
    /// `meeting.json` decode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingPlatform(rawValue: raw) ?? .other
    }

    public var displayName: String {
        switch self {
        case .teams: "Teams"
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .webex: "Webex"
        case .other: "Other"
        }
    }
}
