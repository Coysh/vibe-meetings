import Foundation
import VMCore

public enum MarkdownSummaryWriter {
    /// Wraps the LLM-produced markdown body in the standard front-matter.
    public static func render(meeting: Meeting, body: String, style: SummaryStyle) -> String {
        var header: [(String, Any)] = []
        header.append(("id", meeting.id.uuidString))
        header.append(("title", meeting.title))
        header.append(("generatedAt", Date()))
        if let engine = meeting.summarizationEngine {
            header.append(("summarizationEngine", engine.kind))
        }
        header.append(("model", meeting.modelId))
        header.append(("style", style.rawValue))
        header.append(("schemaVersion", Meeting.currentSchemaVersion))

        var out = FrontMatterCodec.render(orderedHeader: header)
        out += "\n"
        out += body.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n"
        return out
    }
}
