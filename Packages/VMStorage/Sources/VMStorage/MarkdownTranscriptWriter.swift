import Foundation
import VMCore

public enum MarkdownTranscriptWriter {
    public static func render(meeting: Meeting, segments: [TranscriptSegment]) -> String {
        var header: [(String, Any)] = []
        header.append(("id", meeting.id.uuidString))
        header.append(("title", meeting.title))
        header.append(("startedAt", meeting.startedAt))
        if let endedAt = meeting.endedAt { header.append(("endedAt", endedAt)) }
        if let dur = meeting.duration { header.append(("duration", Int(dur))) }
        if let lang = meeting.language { header.append(("language", lang)) }
        header.append(("transcriptionEngine", meeting.transcriptionEngine.kind))
        header.append(("model", meeting.modelId))
        let participants: [[String: Any]] = meeting.participants.map { s in
            var d: [String: Any] = ["id": s.id, "displayName": s.displayName]
            if let c = s.channel { d["channel"] = c.rawValue }
            return d
        }
        header.append(("participants", participants))
        if !meeting.tags.isEmpty { header.append(("tags", meeting.tags)) }
        header.append(("schemaVersion", Meeting.currentSchemaVersion))

        var out = FrontMatterCodec.render(orderedHeader: header)
        out += "\n# \(meeting.title)\n\n"

        if let dur = meeting.duration {
            let dateStr = DateFormatter.shortDateTime.string(from: meeting.startedAt)
            out += "> Recorded \(dateStr) — \(dur.formattedDuration) · \(meeting.modelId) · \(meeting.transcriptionEngine.kind)\n\n"
        }

        let speakerNames = Dictionary(
            uniqueKeysWithValues: meeting.participants.map { ($0.id, $0.displayName) }
        )

        // Merge consecutive segments from the same speaker into a single
        // block so the transcript reads naturally for LLM consumption.
        var lastSpeaker: String?
        for seg in segments where !seg.isPartial {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let name = speakerNames[seg.speakerId] ?? seg.speakerId.capitalized
            if seg.speakerId != lastSpeaker {
                if lastSpeaker != nil { out += "\n" }
                out += "**\(name):**\n"
                lastSpeaker = seg.speakerId
            }
            out += "\(text)\n"
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
}
