import Foundation
import VMCore

/// Loads the system prompts from the bundle, falling back to a baked-in default if the
/// bundled resource is missing (so tests can exercise this without app resources).
public enum PromptLoader {
    public static func systemPrompt(style: SummaryStyle, bundle: Bundle? = nil) -> String {
        let resourceName: String = {
            switch style {
            case .standard, .brief, .verbatimNotes: return "summary.system"
            case .decisionsAndActions: return "action_items.system"
            }
        }()

        if let bundle, let url = bundle.url(forResource: resourceName, withExtension: "md"),
           let data = try? String(contentsOf: url, encoding: .utf8), !data.isEmpty {
            return data
        }
        return Self.fallbackPrompt
    }

    static let fallbackPrompt = """
You are a meeting-notes assistant. The transcript below was produced by a local
speech-to-text model on a 2-channel recording: speaker "You" was on the user's
microphone and "Others" combines all remote participants on system audio. Treat
"You" and "Others" as ground truth for who said what. Do not invent speakers.

Produce Markdown with these sections in order, omitting any that are empty:
1. ## TL;DR        — at most 3 sentences.
2. ## Decisions    — bullets, terse, only things explicitly decided.
3. ## Action items — checkbox bullets `- [ ] **<assignee>** — <action>. _Due: <when or "unspecified">._`.
4. ## Open questions — bullets.

Rules:
- Only use facts present in the transcript (and user notes, if provided). If unclear, write "unspecified".
- If the user provided their own notes at the end of the transcript, incorporate them: they may clarify decisions, add context, or highlight things the transcription missed.
- Do not include preamble, apologies, or restatements of these instructions.
- Output Markdown only, no code fences around the whole document.
"""

    /// Renders a transcript as the user message: speaker-labelled blocks with timestamps,
    /// matching the body of `transcript.md` (no front-matter).
    /// If `userNotes` is non-empty, it is appended after the transcript so the LLM
    /// can incorporate the user's own notes into the summary.
    public static func renderTranscript(
        _ segments: [TranscriptSegment],
        speakerNames: [String: String],
        userNotes: String? = nil
    ) -> String {
        var out = ""
        for seg in segments {
            let name = speakerNames[seg.speakerId] ?? seg.speakerId.capitalized
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += "**[\(seg.start.formattedTimestamp)] \(name)**\n"
            out += "\(text)\n\n"
        }
        if let notes = userNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            out += "---\n\n"
            out += "## User's own notes\n\n"
            out += notes + "\n"
        }
        return out
    }
}
