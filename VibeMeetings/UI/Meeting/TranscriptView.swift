import SwiftUI
import VMCore

struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let participants: [Speaker]
    var meeting: Meeting?
    @State private var copied = false

    private var nameByID: [String: String] {
        Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.displayName) })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with copy button
            if !segments.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        let text = formattedTranscript()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(
                            copied ? "Copied" : "Copy Transcript",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.trailing)
                    .padding(.vertical, 6)
                }
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if segments.isEmpty {
                            Text("No transcript yet — start a recording to see live captions here.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(segments) { seg in
                            TranscriptSegmentRow(
                                segment: seg,
                                speakerName: nameByID[seg.speakerId] ?? seg.speakerId.capitalized
                            )
                            .id(seg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: segments.last?.id) { _, newID in
                    if let newID { withAnimation { proxy.scrollTo(newID, anchor: .bottom) } }
                }
            }
        }
    }

    /// Formats the transcript as clean plain text suitable for pasting into an LLM.
    private func formattedTranscript() -> String {
        var lines: [String] = []

        // Header with meeting context
        if let meeting {
            lines.append("# \(meeting.title)")
            lines.append("Date: \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))")
            if let dur = meeting.duration {
                lines.append("Duration: \(dur.formattedDuration)")
            }
            if let attendees = meeting.attendees, !attendees.isEmpty {
                lines.append("Attendees: \(attendees.joined(separator: ", "))")
            }
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        // Transcript body — group consecutive segments by the same speaker,
        // filtering out noise artifacts that add no value for an LLM.
        var currentSpeaker = ""
        for seg in segments where !seg.isPartial {
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces)
            if Self.isNoiseSegment(trimmed) { continue }

            let name = nameByID[seg.speakerId] ?? seg.speakerId.capitalized
            let timestamp = "[\(seg.start.formattedTimestamp)]"

            if name != currentSpeaker {
                if !currentSpeaker.isEmpty { lines.append("") }
                lines.append("**\(name)** \(timestamp)")
                currentSpeaker = name
            }
            lines.append(trimmed)
        }

        return lines.joined(separator: "\n")
    }

    /// Returns `true` if the segment text is a noise/silence artifact that
    /// adds no semantic value (e.g. "[silence]", "(keyboard clicking)").
    private static func isNoiseSegment(_ text: String) -> Bool {
        let lower = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip bracket/paren wrappers: "[silence]" → "silence", "(keyboard clicking)" → "keyboard clicking"
        let inner: String
        if (lower.hasPrefix("[") && lower.hasSuffix("]"))
            || (lower.hasPrefix("(") && lower.hasSuffix(")")) {
            inner = String(lower.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        } else {
            inner = lower
        }

        let noisePatterns: Set<String> = [
            "silence",
            "light wind",
            "wind",
            "bubbling",
            "keyboard clicking",
            "keyboard tapping",
            "keyboard clacking",
            "typing",
            "mouse clicking",
            "clicking",
            "tapping",
            "static",
            "background noise",
            "inaudible",
            "unintelligible",
            "blank audio",
        ]

        return noisePatterns.contains(inner)
    }
}

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let speakerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(segment.start.formattedTimestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(speakerName)
                    .font(.caption.bold())
                    .foregroundStyle(speakerColor)
                if segment.isPartial {
                    Text("…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(segment.text)
                .textSelection(.enabled)
        }
        .opacity(segment.isPartial ? 0.7 : 1)
    }

    private var speakerColor: Color {
        switch segment.channel {
        case .mic: return .blue
        case .system: return .purple
        case .mixed: return .secondary
        }
    }
}
