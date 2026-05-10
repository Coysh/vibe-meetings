import Foundation
import EventKit

/// Pure regex-driven detector for Microsoft Teams join URLs.
///
/// Scans `event.location`, `event.notes`, and `event.url?.absoluteString`
/// (Outlook on macOS sometimes places the join link in the iCalendar URL
/// field) for any of the three known Teams URL shapes. Returns the first
/// match — case-insensitive on scheme + host.
public enum TeamsURLDetector {
    private static let patterns: [String] = [
        #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"']+"#,
        #"https://teams\.live\.com/meet/[^\s<>"']+"#,
        #"https://teams\.microsoft\.com/meet/[^\s<>"']+"#
    ]

    private static let regexes: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
    }

    public static func detect(in event: EKEvent) -> URL? {
        let haystacks = [event.location, event.notes, event.url?.absoluteString]
            .compactMap { $0 }
        return detect(inAny: haystacks)
    }

    /// Convenience for tests and code paths that already have plain strings.
    public static func detect(inAny strings: [String]) -> URL? {
        for s in strings {
            if let url = detect(in: s) { return url }
        }
        return nil
    }

    public static func detect(in string: String) -> URL? {
        for re in regexes {
            let range = NSRange(string.startIndex..., in: string)
            if let m = re.firstMatch(in: string, range: range),
               let r = Range(m.range, in: string) {
                return URL(string: String(string[r]))
            }
        }
        return nil
    }
}
