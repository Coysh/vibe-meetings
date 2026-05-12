import Foundation
import VMCore

public enum MarkdownTranscriptWriter {
    /// Render the full transcript.md file with YAML front-matter.
    /// Includes summary, notes, and actions sections before the collapsible transcript.
    public static func render(
        meeting: Meeting,
        segments: [TranscriptSegment],
        summary: String? = nil,
        notes: String? = nil
    ) -> String {
        // --- Front-matter ---
        var header: [(String, Any)] = []

        header.append(("type", meeting.resolvedType.rawValue))

        let datePrefix = DateFormatter.dateOnly.string(from: meeting.startedAt)
        header.append(("title", "\(datePrefix) - \(meeting.title)"))

        if meeting.resolvedType == .oneOnOne, let person = meeting.person {
            header.append(("person", person))
        }

        header.append(("date", DateFormatter.dateOnly.string(from: meeting.startedAt)))
        header.append(("time", DateFormatter.timeOnly.string(from: meeting.startedAt)))

        if let org = meeting.org {
            header.append(("org", org))
        }

        if let attendees = meeting.attendees, !attendees.isEmpty {
            header.append(("attendees", attendees))
        }

        if let labels = meeting.labels, !labels.isEmpty {
            header.append(("labels", labels))
        }

        let tags = meeting.computedTags
        if !tags.isEmpty {
            header.append(("tags", tags))
        }

        header.append(("transcript", true))
        header.append(("source", "vibe-meetings"))

        var out = FrontMatterCodec.render(orderedHeader: header)

        // --- Title heading ---
        let shortDate = DateFormatter.shortDateDisplay.string(from: meeting.startedAt)
        let time = DateFormatter.timeOnly.string(from: meeting.startedAt)
        out += "\n# \(meeting.title) \u{2014} \(shortDate), \(time)\n\n"

        // --- Summary section ---
        out += "## Summary\n"
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        out += "\n"

        // --- Notes section ---
        out += "## Notes\n"
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        } else {
            out += "_(empty)_\n"
        }
        out += "\n"

        // --- Actions section ---
        out += "## Actions\n- [ ] \n\n"

        // --- Separator ---
        out += "---\n\n"

        // --- Transcript in collapsible callout ---
        out += "## Full transcript\n"
        out += "> [!note]- Expand transcript\n"
        out += "> Speaker labels are placeholders \u{2014} rename if useful.\n>\n"

        let speakerNames = Dictionary(
            uniqueKeysWithValues: meeting.participants.map { ($0.id, $0.displayName) }
        )

        var lastSpeaker: String?
        for seg in segments where !seg.isPartial {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let name = speakerNames[seg.speakerId] ?? seg.speakerId.capitalized
            let timestamp = seg.start.formattedTimestamp
            if seg.speakerId != lastSpeaker {
                if lastSpeaker != nil { out += ">\n" }
                out += "> **\(name)** [\(timestamp)]\n"
                lastSpeaker = seg.speakerId
            }
            out += "> \(text)\n"
        }
        return out
    }
}

extension DateFormatter {
    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let shortDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd MMM yyyy"
        return f
    }()
}
