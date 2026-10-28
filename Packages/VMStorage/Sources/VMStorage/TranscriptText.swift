import Foundation
import VMCore

/// A meeting's transcript as plain text, for readers that don't need the per-word
/// timings: the MCP tools and the search index.
public enum TranscriptText {

    /// One line of transcript: consecutive final segments from one speaker.
    public struct Utterance: Sendable, Equatable {
        public let start: TimeInterval
        public let speaker: String
        public let text: String
        /// The first segment of the line, for jumping to it.
        public let segmentID: UUID?
    }

    /// The transcript as utterances, from `segments.json`. Empty when there is none
    /// (e.g. some imported meetings only have `transcript.md`; see `markdownTranscript`).
    public static func utterances(meeting: Meeting, folderURL: URL, maxLineLength: Int = 1500) -> [Utterance] {
        let url = MeetingFolder(url: folderURL).segmentsURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let segments = try? JSONDecoder().decode([LiteSegment].self, from: data) else { return [] }

        let names = Dictionary(meeting.participants.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var out: [Utterance] = []
        var current: (start: TimeInterval, speakerId: String, text: String, id: UUID?)?
        func flush() {
            guard let c = current else { return }
            out.append(Utterance(start: c.start, speaker: names[c.speakerId] ?? c.speakerId.capitalized, text: c.text, segmentID: c.id))
        }
        for seg in segments where !seg.isPartial {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var c = current, c.speakerId == seg.speakerId, c.text.count + text.count < maxLineLength {
                c.text += " " + text
                current = c
            } else {
                flush()
                current = (seg.start, seg.speakerId, text, seg.id)
            }
        }
        flush()
        return out
    }

    /// The "Full transcript" section of `transcript.md`, with the callout markup stripped.
    public static func markdownTranscript(folderURL: URL) -> String? {
        guard let md = readText(MeetingFolder(url: folderURL).transcriptURL),
              let range = md.range(of: "## Full transcript") else { return nil }
        let lines = md[range.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var l = line
                if l.hasPrefix(">") { l = l.dropFirst() }
                if l.hasPrefix(" ") { l = l.dropFirst() }
                return l
            }
            .filter { !$0.hasPrefix("[!note]") && !$0.hasPrefix("Speaker labels are placeholders") }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// A file's text, trimmed; nil when missing or blank.
    public static func readText(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// `TranscriptSegment` without the per-word timings, which are most of the file
/// and which these readers never use.
private struct LiteSegment: Decodable {
    let id: UUID?
    let speakerId: String
    let start: TimeInterval
    let text: String
    let isPartial: Bool
}
