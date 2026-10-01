import Foundation
import EventKit
import VMCore

/// An online-meeting join link found in a calendar event.
public struct MeetingLink: Sendable, Hashable {
    public let url: URL
    public let platform: MeetingPlatform

    public init(url: URL, platform: MeetingPlatform) {
        self.url = url
        self.platform = platform
    }
}

/// Regex-driven detector for Teams, Zoom, Google Meet and Webex join links.
///
/// Scans `event.url` (Outlook on macOS sometimes places the join link in the
/// iCalendar URL field), then `location`, then `notes`. Within a string the
/// earliest match wins, so the link a human would click first is chosen.
public enum MeetingURLDetector {
    private static let terminator = #"[^\s<>"'\]\)]+"#

    private static let patterns: [(MeetingPlatform, String)] = [
        (.teams, #"https://teams\.microsoft\.com/l/meetup-join/"# + terminator),
        (.teams, #"https://teams\.live\.com/meet/"# + terminator),
        (.teams, #"https://teams\.microsoft\.com/meet/"# + terminator),
        (.zoom, #"https://(?:[\w-]+\.)?zoom(?:gov)?\.(?:us|com)/(?:j|my|w|s)/"# + terminator),
        (.zoom, #"zoommtg://"# + terminator),
        (.googleMeet, #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\?"# + terminator + ")?"),
        (.webex, #"https://[\w-]+\.webex\.com/(?:meet|join|wbxmjs|[\w-]+/j\.php)"# + terminator),
    ]

    private static let regexes: [(MeetingPlatform, NSRegularExpression)] = patterns.compactMap { platform, pattern in
        (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { (platform, $0) }
    }

    public static func detect(in event: EKEvent) -> MeetingLink? {
        let haystacks = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        return detect(inAny: haystacks)
    }

    /// First link found, checking each string in order.
    public static func detect(inAny strings: [String]) -> MeetingLink? {
        for s in strings {
            if let link = detect(in: s) { return link }
        }
        return nil
    }

    /// Earliest join link in `string`, if any, optionally limited to one platform.
    public static func detect(in string: String, platform only: MeetingPlatform? = nil) -> MeetingLink? {
        let range = NSRange(string.startIndex..., in: string)
        var best: (location: Int, link: MeetingLink)?
        for (platform, re) in regexes where only == nil || only == platform {
            guard let m = re.firstMatch(in: string, range: range),
                  let r = Range(m.range, in: string),
                  let url = URL(string: clean(String(string[r])))
            else { continue }
            if best == nil || m.range.location < best!.location {
                best = (m.range.location, MeetingLink(url: url, platform: platform))
            }
        }
        return best?.link
    }

    /// Trim sentence punctuation that the greedy match picks up and decode
    /// HTML-escaped ampersands from rich-text invites.
    static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "&amp;", with: "&")
        while let last = s.last, ".,;:!?".contains(last) {
            s.removeLast()
        }
        return s
    }
}
