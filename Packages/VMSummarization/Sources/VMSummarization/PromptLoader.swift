import Foundation
import VMCore

/// Loads the system prompts from the bundle, falling back to a baked-in default if the
/// bundled resource is missing (so tests can exercise this without app resources).
public enum PromptLoader {
    /// Returns the system prompt for the LLM. If `customPrompt` is non-empty it is
    /// used instead of the bundled or fallback prompt, giving users full control
    /// over the summarization instructions.
    public static func systemPrompt(style: SummaryStyle, bundle: Bundle? = nil, customPrompt: String? = nil) -> String {
        if let custom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }

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

    public static let fallbackPrompt = """
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
    /// Includes meeting metadata and user notes as context for the LLM.
    public static func renderTranscript(
        _ segments: [TranscriptSegment],
        speakerNames: [String: String],
        meeting: Meeting? = nil,
        userNotes: String? = nil
    ) -> String {
        var out = ""

        // Prepend meeting metadata so the LLM has context.
        if let m = meeting {
            out += "## Meeting info\n"
            out += "- **Title:** \(m.title)\n"
            out += "- **Date:** \(m.startedAt.formatted(date: .abbreviated, time: .shortened))\n"
            if let type = m.meetingType {
                out += "- **Type:** \(type == .oneOnOne ? "1:1" : "Group meeting")\n"
            }
            if let org = m.org {
                out += "- **Organisation:** \(org)\n"
            }
            if let attendees = m.attendees, !attendees.isEmpty {
                out += "- **Attendees:** \(attendees.joined(separator: ", "))\n"
            }
            if let labels = m.labels, !labels.isEmpty {
                out += "- **Labels:** \(labels.joined(separator: ", "))\n"
            }
            if let dur = m.duration {
                out += "- **Duration:** \(dur.formattedDuration)\n"
            }
            if !m.participants.isEmpty {
                out += "- **Speakers:** \(m.participants.map(\.displayName).joined(separator: ", "))\n"
            }
            out += "\n---\n\n"
        }

        out += "## Transcript\n\n"

        for seg in segments {
            let name = speakerNames[seg.speakerId] ?? seg.speakerId.capitalized
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !isNoiseSegment(text) else { continue }
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

    /// Returns true if the segment text is a noise artifact from the
    /// speech-to-text model (silence markers, non-speech sounds, music cues)
    /// that should be stripped before sending to the LLM.
    private static func isNoiseSegment(_ text: String) -> Bool {
        let lower = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return noisePatterns.contains(lower)
    }

    private static let noisePatterns: Set<String> = [
        "silence",
        "music",
        "laughter",
        "applause",
        "keyboard clicking",
        "keyboard tapping",
        "typing",
        "phone ringing",
        "ringing",
        "bubbling",
        "light wind",
        "wind",
        "coughing",
        "sneezing",
        "breathing",
        "inaudible",
        "unintelligible",
        "background noise",
        "static",
        "beep",
        "beeping",
        "click",
        "clicking",
        "rustling",
        "shuffling",
        "door closing",
        "door opening",
        "footsteps",
    ]
}
