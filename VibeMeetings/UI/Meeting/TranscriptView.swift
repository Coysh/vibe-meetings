import SwiftUI
import VMCore

struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let participants: [Speaker]
    var meeting: Meeting?
    @Binding var isSearching: Bool
    @State private var copied = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var nameByID: [String: String] {
        Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.displayName) })
    }

    /// Segment IDs that contain the current search query.
    private var matchingIDs: Set<UUID> {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let query = searchText.lowercased()
        var ids = Set<UUID>()
        for seg in segments {
            if seg.text.lowercased().contains(query) {
                ids.insert(seg.id)
            }
            let name = nameByID[seg.speakerId] ?? seg.speakerId
            if name.lowercased().contains(query) {
                ids.insert(seg.id)
            }
        }
        return ids
    }

    private var matchCount: Int { matchingIDs.count }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with copy button
            if !segments.isEmpty {
                HStack {
                    if isSearching {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            TextField("Search transcript…", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.callout)
                                .focused($searchFocused)
                            if !searchText.isEmpty {
                                Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            Button {
                                isSearching = false
                                searchText = ""
                            } label: {
                                Text("Done")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.bar)
                    }
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
                                speakerName: nameByID[seg.speakerId] ?? seg.speakerId.capitalized,
                                searchQuery: isSearching ? searchText : "",
                                isMatch: matchingIDs.contains(seg.id)
                            )
                            .id(seg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: segments.last?.id) { _, newID in
                    if let newID, !isSearching { withAnimation { proxy.scrollTo(newID, anchor: .bottom) } }
                }
                .onChange(of: searchText) {
                    // Scroll to the first match when typing.
                    if let firstMatch = segments.first(where: { matchingIDs.contains($0.id) }) {
                        withAnimation { proxy.scrollTo(firstMatch.id, anchor: .center) }
                    }
                }
            }
        }
        .onChange(of: isSearching) {
            if isSearching {
                searchFocused = true
            } else {
                searchText = ""
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
    var searchQuery: String = ""
    var isMatch: Bool = false

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
            highlightedText(segment.text)
                .textSelection(.enabled)
        }
        .opacity(segment.isPartial ? 0.7 : 1)
        .padding(.vertical, isMatch ? 2 : 0)
        .padding(.horizontal, isMatch ? 4 : 0)
        .background(isMatch ? Color.yellow.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func highlightedText(_ text: String) -> some View {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty || !isMatch {
            Text(text)
        } else {
            Text(buildHighlightedAttributedString(text: text, query: query))
        }
    }

    private func buildHighlightedAttributedString(text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let lower = text.lowercased()
        var searchStart = lower.startIndex
        while let range = lower.range(of: query, range: searchStart..<lower.endIndex) {
            let attrStart = AttributedString.Index(range.lowerBound, within: attributed)
            let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
            if let attrStart, let attrEnd {
                attributed[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.4)
                attributed[attrStart..<attrEnd].foregroundColor = .black
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    private var speakerColor: Color {
        switch segment.channel {
        case .mic: return .blue
        case .system: return .purple
        case .mixed: return .secondary
        }
    }
}
