import Foundation
import EventKit

/// Microsoft Teams join-link detection. Thin wrapper over
/// `MeetingURLDetector`, kept for existing callers and tests.
public enum TeamsURLDetector {
    public static func detect(in event: EKEvent) -> URL? {
        let haystacks = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }
        return detect(inAny: haystacks)
    }

    public static func detect(inAny strings: [String]) -> URL? {
        for s in strings {
            if let url = detect(in: s) { return url }
        }
        return nil
    }

    public static func detect(in string: String) -> URL? {
        MeetingURLDetector.detect(in: string, platform: .teams)?.url
    }
}
