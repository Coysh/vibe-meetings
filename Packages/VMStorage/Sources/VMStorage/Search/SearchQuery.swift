import Foundation
import VMCore

/// Where in a meeting a search hit was found.
public enum SearchKind: String, Sendable, CaseIterable, Codable, Hashable {
    /// Title, calendar title, attendees and organisation.
    case title
    case summary
    case notes
    /// A template write-up (`templates/<id>.md`).
    case template
    /// One line of the transcript.
    case transcript

    /// How much a hit here counts towards a meeting's rank (as in the MCP search and library chat).
    var weight: Double {
        switch self {
        case .title: 3
        case .summary, .notes: 2
        case .template: 1.5
        case .transcript: 1
        }
    }
}

/// A date filter. Presets are relative to when the search runs.
public enum SearchDateRange: Sendable, Hashable {
    case pastWeek
    case pastMonth
    case pastThreeMonths
    case thisYear
    /// Whole days, both ends included.
    case custom(from: Date, to: Date)

    /// The half-open interval `[start, end)` this range covers.
    public func interval(now: Date = .now, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        func back(_ component: Calendar.Component, _ n: Int) -> Date {
            calendar.date(byAdding: component, value: -n, to: calendar.startOfDay(for: now)) ?? now
        }
        switch self {
        case .pastWeek: return (back(.day, 7), tomorrow)
        case .pastMonth: return (back(.month, 1), tomorrow)
        case .pastThreeMonths: return (back(.month, 3), tomorrow)
        case .thisYear:
            let start = calendar.dateInterval(of: .year, for: now)?.start ?? back(.year, 1)
            return (start, tomorrow)
        case .custom(let from, let to):
            let start = calendar.startOfDay(for: min(from, to))
            let lastDay = calendar.startOfDay(for: max(from, to))
            return (start, calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay)
        }
    }
}

public struct SearchFilters: Sendable, Hashable {
    public var dateRange: SearchDateRange?
    /// A folder relative to the library root ("Clients/Acme"), subfolders included.
    public var folderPath: String?
    /// Meetings with any of these attendees or named speakers.
    public var people: Set<String> = []
    public var org: String?
    public var meetingType: MeetingType?
    /// Meetings with any of these labels.
    public var labels: Set<String> = []
    /// Only meetings whose transcript was transcribed again from the recording.
    public var improvedOnly = false
    /// Where to look; empty means everywhere.
    public var kinds: Set<SearchKind> = []
    /// Only transcript lines spoken by this speaker.
    public var speaker: String?

    public init() {}

    public var isEmpty: Bool { self == SearchFilters() }
}

public struct SearchQuery: Sendable, Hashable {
    public enum Sort: String, Sendable, Hashable, CaseIterable {
        case relevance
        case newest
    }

    public var text: String
    public var filters: SearchFilters
    public var sort: Sort

    public init(text: String = "", filters: SearchFilters = SearchFilters(), sort: Sort = .relevance) {
        self.text = text
        self.filters = filters
        self.sort = sort
    }

    /// The text has words to match (not just filters, or "-excluded" words alone).
    public var hasWords: Bool { SearchQuery.terms(for: text) != nil }

    /// No words to match and no filters: nothing to show.
    public var isBlank: Bool { !hasWords && filters.isEmpty }

    /// The user's words as FTS5 terms, each quoted (so FTS syntax in the input —
    /// `*`, `(`, `NEAR`, `col:` — is just text). Nil when there's nothing to match.
    struct Terms: Equatable {
        /// Each must appear somewhere in a meeting.
        var positives: [String]
        /// None may appear anywhere in a meeting.
        var negatives: [String]
    }

    /// `"quoted words"` stay a phrase, `-word` excludes, and the last plain word
    /// matches as a prefix so results follow typing.
    static func terms(for text: String) -> Terms? {
        var positives: [(term: String, isPhrase: Bool)] = []
        var negatives: [String] = []

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace { i = text.index(after: i); continue }
            var negate = false
            var start = i
            if c == "-", text.index(after: i) < text.endIndex, !text[text.index(after: i)].isWhitespace {
                negate = true
                start = text.index(after: i)
            }
            let term: String
            let isPhrase: Bool
            if text[start] == "\"" {
                let open = text.index(after: start)
                let close = text[open...].firstIndex(of: "\"") ?? text.endIndex
                term = String(text[open..<close])
                isPhrase = true
                i = close < text.endIndex ? text.index(after: close) : close
            } else {
                let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                term = String(text[start..<end])
                isPhrase = false
                i = end
            }
            // A term the tokenizer would reduce to nothing ("*", "--") can't match anything.
            guard term.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if negate { negatives.append(term) } else { positives.append((term, isPhrase)) }
        }

        guard !positives.isEmpty else { return nil }
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var quotedPositives = positives.map { quoted($0.term) }
        if let last = positives.last, !last.isPhrase, last.term.count >= 2 {
            quotedPositives[quotedPositives.count - 1] += "*"
        }
        return Terms(positives: quotedPositives, negatives: negatives.map(quoted))
    }
}

// MARK: - Results

/// One matching passage, with the matched words between `SearchSnippet.highlightStart` and `highlightEnd`.
public struct SearchSnippet: Sendable, Hashable {
    public static let highlightStart: Character = "\u{E000}"
    public static let highlightEnd: Character = "\u{E001}"

    public let kind: SearchKind
    public let text: String
    /// Transcript lines: who said it and when.
    public let speaker: String?
    public let start: TimeInterval?
    public let segmentID: UUID?
    /// Template write-ups: the template id.
    public let label: String?
}

public struct SearchHit: Sendable, Identifiable, Hashable {
    public let meetingID: UUID
    public let startedAt: Date
    public let score: Double
    /// Where the best match was, to open the meeting on that tab.
    public let bestKind: SearchKind?
    /// Up to three passages: the best summary/notes/write-up passage, then transcript lines in meeting order.
    public let snippets: [SearchSnippet]
    /// How many transcript lines matched in all.
    public let transcriptMatches: Int
    public var id: UUID { meetingID }
}

public struct SearchResults: Sendable {
    public let hits: [SearchHit]
    /// No words were given: the hits are the filtered meetings, newest first, without snippets.
    public let isBrowse: Bool

    public static let empty = SearchResults(hits: [], isBrowse: false)
}

/// Values the filter menus offer, with how many meetings each covers.
public struct SearchFacets: Sendable, Equatable {
    public struct Value: Sendable, Hashable, Identifiable {
        public let name: String
        public let count: Int
        public var id: String { name }
    }

    public var people: [Value] = []
    public var speakers: [Value] = []
    public var orgs: [Value] = []
    public var labels: [Value] = []
    public var meetingCount = 0

    public init() {}
}
