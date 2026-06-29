import SwiftUI
import VMCore

struct TranscriptView: View {
    @Binding var segments: [TranscriptSegment]
    let participants: [Speaker]
    var meeting: Meeting?
    @Binding var isSearching: Bool
    var isEditable: Bool = false
    var onSave: (([TranscriptSegment]) -> Void)? = nil
    @State private var copied = false
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var editingSegmentID: UUID? = nil
    @State private var editText = ""
    @State private var showTrimConfirm = false
    @State private var trimAfterSegmentID: UUID? = nil
    @State private var selectedSegmentIDs: Set<UUID> = []
    @State private var showDeleteSelectedConfirm = false
    @FocusState private var searchFocused: Bool
    @FocusState private var editFocused: Bool

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
                    if isEditable && isEditing {
                        // Bulk selection controls
                        HStack(spacing: 6) {
                            Button {
                                if selectedSegmentIDs.count == segments.count {
                                    selectedSegmentIDs.removeAll()
                                } else {
                                    selectedSegmentIDs = Set(segments.map(\.id))
                                }
                            } label: {
                                Text(selectedSegmentIDs.count == segments.count ? "Deselect All" : "Select All")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if !selectedSegmentIDs.isEmpty {
                                Button(role: .destructive) {
                                    showDeleteSelectedConfirm = true
                                } label: {
                                    Label("Delete \(selectedSegmentIDs.count)", systemImage: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    if isEditable {
                        Button {
                            if isEditing {
                                commitEdit()
                                isEditing = false
                                selectedSegmentIDs.removeAll()
                            } else {
                                isEditing = true
                            }
                        } label: {
                            Label(
                                isEditing ? "Done Editing" : "Edit",
                                systemImage: isEditing ? "checkmark.circle" : "pencil"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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
                            HStack(alignment: .top, spacing: 8) {
                                if isEditing {
                                    // Selection checkbox for bulk operations
                                    Button {
                                        if selectedSegmentIDs.contains(seg.id) {
                                            selectedSegmentIDs.remove(seg.id)
                                        } else {
                                            selectedSegmentIDs.insert(seg.id)
                                        }
                                    } label: {
                                        Image(systemName: selectedSegmentIDs.contains(seg.id)
                                              ? "checkmark.circle.fill"
                                              : "circle")
                                            .foregroundStyle(selectedSegmentIDs.contains(seg.id) ? .blue : .secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Select this segment")
                                }

                                if isEditing && editingSegmentID == seg.id {
                                    // Inline editing
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(seg.start.formattedTimestamp)
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.tertiary)
                                            Text(nameByID[seg.speakerId] ?? seg.speakerId.capitalized)
                                                .font(.caption.bold())
                                                .foregroundStyle(.secondary)
                                        }
                                        TextField("Segment text", text: $editText, axis: .vertical)
                                            .textFieldStyle(.plain)
                                            .focused($editFocused)
                                            .onSubmit {
                                                commitEdit()
                                            }
                                            .padding(6)
                                            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                        HStack(spacing: 8) {
                                            Button("Save") { commitEdit() }
                                                .buttonStyle(.borderedProminent)
                                                .controlSize(.small)
                                            Button("Cancel") {
                                                editingSegmentID = nil
                                                editText = ""
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                } else {
                                    TranscriptSegmentRow(
                                        segment: seg,
                                        speakerName: nameByID[seg.speakerId] ?? seg.speakerId.capitalized,
                                        searchQuery: isSearching ? searchText : "",
                                        isMatch: matchingIDs.contains(seg.id)
                                    )
                                    .onTapGesture {
                                        if isEditing {
                                            commitEdit()
                                            editingSegmentID = seg.id
                                            editText = seg.text
                                            editFocused = true
                                        }
                                    }
                                }
                            }
                            .id(seg.id)
                            .contextMenu {
                                if isEditable {
                                    Button {
                                        if !isEditing { isEditing = true }
                                        commitEdit()
                                        editingSegmentID = seg.id
                                        editText = seg.text
                                        editFocused = true
                                    } label: {
                                        Label("Edit Segment", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        if !isEditing { isEditing = true }
                                        deleteSegment(seg.id)
                                    } label: {
                                        Label("Delete Segment", systemImage: "trash")
                                    }
                                    Divider()
                                    Button {
                                        if !isEditing { isEditing = true }
                                        selectFromHereToEnd(seg.id)
                                    } label: {
                                        Label("Select From Here to End", systemImage: "arrow.down.to.line")
                                    }
                                    Button {
                                        if !isEditing { isEditing = true }
                                        selectFromStartToHere(seg.id)
                                    } label: {
                                        Label("Select From Start to Here", systemImage: "arrow.up.to.line")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        trimAfterSegmentID = seg.id
                                        showTrimConfirm = true
                                    } label: {
                                        Label("Trim After This Segment", systemImage: "scissors")
                                    }
                                }
                            }
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
        .alert("Trim Transcript", isPresented: $showTrimConfirm) {
            Button("Cancel", role: .cancel) {
                trimAfterSegmentID = nil
            }
            Button("Trim", role: .destructive) {
                if let trimID = trimAfterSegmentID {
                    trimAfterSegment(trimID)
                    trimAfterSegmentID = nil
                }
            }
        } message: {
            if let trimID = trimAfterSegmentID,
               let idx = segments.firstIndex(where: { $0.id == trimID }) {
                let count = segments.count - idx - 1
                Text("This will remove \(count) segment\(count == 1 ? "" : "s") after this point. This cannot be undone.")
            } else {
                Text("Remove all segments after this point?")
            }
        }
        .alert("Delete Selected Segments", isPresented: $showDeleteSelectedConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete \(selectedSegmentIDs.count) Segments", role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text("This will remove \(selectedSegmentIDs.count) segment\(selectedSegmentIDs.count == 1 ? "" : "s"). This cannot be undone.")
        }
    }

    // MARK: - Editing helpers

    private func commitEdit() {
        guard let editID = editingSegmentID else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let idx = segments.firstIndex(where: { $0.id == editID }) {
            segments[idx].text = trimmed
            onSave?(segments)
        }
        editingSegmentID = nil
        editText = ""
    }

    private func deleteSegment(_ id: UUID) {
        segments.removeAll { $0.id == id }
        if editingSegmentID == id {
            editingSegmentID = nil
            editText = ""
        }
        onSave?(segments)
    }

    private func trimAfterSegment(_ id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        segments = Array(segments.prefix(through: idx))
        editingSegmentID = nil
        editText = ""
        selectedSegmentIDs.removeAll()
        onSave?(segments)
    }

    private func deleteSelected() {
        segments.removeAll { selectedSegmentIDs.contains($0.id) }
        editingSegmentID = nil
        editText = ""
        selectedSegmentIDs.removeAll()
        onSave?(segments)
    }

    private func selectFromHereToEnd(_ id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let ids = segments[idx...].map(\.id)
        selectedSegmentIDs.formUnion(ids)
    }

    private func selectFromStartToHere(_ id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let ids = segments[...idx].map(\.id)
        selectedSegmentIDs.formUnion(ids)
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
