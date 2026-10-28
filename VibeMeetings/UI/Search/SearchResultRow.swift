import SwiftUI
import VMCore
import VMStorage

/// One meeting in the search results: title, where and when, then up to three
/// matching passages with the matched words picked out. Clicking a passage
/// opens the meeting there; clicking elsewhere opens it at its best match.
struct SearchResultRow: View {
    let item: MeetingItem
    let hit: SearchHit
    let onOpen: (MeetingFocus?) -> Void

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.meeting.title)
                        .font(Tokens.rowTitle)
                        .lineLimit(1)
                    Text(details)
                        .font(Tokens.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.m)
                if env.refinementService.isImproved(item.id) {
                    Image(systemName: "sparkles")
                        .font(Tokens.secondary)
                        .foregroundStyle(Color.accentColor)
                        .help("Transcript improved: transcribed again from the recording")
                        .accessibilityLabel("Transcript improved")
                }
                Text(item.meeting.startedAt, format: .dateTime.day().month(.abbreviated).year())
                    .font(Tokens.secondary)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(hit.snippets.enumerated()), id: \.offset) { _, snippet in
                Button { onOpen(Self.focus(for: snippet)) } label: { passage(snippet) }
                    .buttonStyle(.plain)
                    .help(snippet.kind == .transcript ? "Open the transcript here" : "Open the \(kindName(snippet).lowercased())")
            }

            let shownLines = hit.snippets.filter { $0.kind == .transcript }.count
            if hit.transcriptMatches > shownLines {
                let more = hit.transcriptMatches - shownLines
                Text("\(more) more in the transcript")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { onOpen(bestFocus) }
        .accessibilityElement(children: .contain)
    }

    /// Folder · who was there.
    private var details: String {
        [item.folderName, item.subtitle == item.folderName ? "" : item.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func passage(_ snippet: SearchSnippet) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label(for: snippet))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Text(Self.highlighted(snippet.text))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.leading, Tokens.Space.s)
        .overlay(alignment: .leading) {
            Rectangle().fill(Tokens.stroke).frame(width: 2)
        }
        .contentShape(Rectangle())
    }

    private func label(for snippet: SearchSnippet) -> String {
        if snippet.kind == .transcript {
            let who = snippet.speaker ?? "Transcript"
            return snippet.start.map { "\($0.formattedTimestamp) \(who)" } ?? who
        }
        return kindName(snippet)
    }

    private func kindName(_ snippet: SearchSnippet) -> String {
        switch snippet.kind {
        case .title: "Title"
        case .summary: "Summary"
        case .notes: "Notes"
        case .transcript: "Transcript"
        case .template:
            snippet.label.flatMap { env.summaryTemplates.template(id: $0)?.name } ?? "Write-up"
        }
    }

    /// Where a click on the row (not a passage) opens: the passage that ranked best.
    private var bestFocus: MeetingFocus? {
        let best = hit.snippets.first { $0.kind == hit.bestKind } ?? hit.snippets.first
        return best.flatMap(Self.focus(for:))
    }

    static func focus(for snippet: SearchSnippet) -> MeetingFocus? {
        switch snippet.kind {
        case .title: nil
        case .summary: .summary
        case .notes: .notes
        case .template: snippet.label.map(MeetingFocus.template)
        case .transcript:
            .transcript(TranscriptJump(segmentID: snippet.segmentID, start: snippet.start, find: firstMatch(in: snippet.text)))
        }
    }

    /// The first highlighted words, to find in the transcript.
    private static func firstMatch(in text: String) -> String {
        guard let open = text.firstIndex(of: SearchSnippet.highlightStart) else { return "" }
        let rest = text[text.index(after: open)...]
        let close = rest.firstIndex(of: SearchSnippet.highlightEnd) ?? rest.endIndex
        return String(rest[..<close])
    }

    /// The passage on one line, with Markdown punctuation dropped and the matched words in bold accent.
    static func highlighted(_ text: String) -> AttributedString {
        let flat = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(^|\n)\s*(#+|[-*]|\d+\.)\s+"#, with: "$1", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " · ")

        var out = AttributedString()
        var buffer = ""
        var isMatch = false
        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            if isMatch {
                run.font = .callout.weight(.semibold)
                run.foregroundColor = .primary
            }
            out += run
            buffer = ""
        }
        for ch in flat {
            if ch == SearchSnippet.highlightStart {
                flush(); isMatch = true
            } else if ch == SearchSnippet.highlightEnd {
                flush(); isMatch = false
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return out
    }
}
