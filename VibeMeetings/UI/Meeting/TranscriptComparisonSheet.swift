import SwiftUI
import VMCore

/// The live transcript against the improved one, for a meeting whose transcript was improved. "Changes" is the
/// current transcript with what improving found marked in place; "Live" and "Improved" show each on its own.
struct TranscriptComparisonSheet: View {
    let meetingID: UUID
    let folderURL: URL
    let record: RefinementRecord?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case live = "Live"
        case improved = "Improved"
        var id: String { rawValue }
    }

    private enum LoadState {
        case loading
        case ready(TranscriptDiff.Result, live: [TranscriptSegment])
        case unavailable
    }

    @State private var mode: Mode = .changes
    @State private var state: LoadState = .loading
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 640, height: 600)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack {
                Text("Live and improved transcript").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if case .ready(let result, _) = state {
                Text(summary(result))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Show", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    Spacer()
                    if mode == .changes { legend }
                }
            }
        }
        .padding(Tokens.Space.l)
    }

    private func summary(_ result: TranscriptDiff.Result) -> String {
        let live = result.liveWords.formatted()
        let improved = result.improvedWords.formatted()
        var text = "\(live) words live → \(improved) words improved"
        if result.liveWords > 0 {
            let change = Double(result.improvedWords - result.liveWords) / Double(result.liveWords)
            text += " (\(change >= 0 ? "+" : "−")\(Int((abs(change) * 100).rounded()))%)"
        }
        if let model = record?.model { text += ", with \(model)" }
        return text + "."
    }

    private var legend: some View {
        HStack(spacing: Tokens.Space.m) {
            Text("added")
                .padding(.horizontal, 4)
                .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
            Text("live only")
                .strikethrough()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView(
                "No live transcript to compare",
                systemImage: "text.badge.xmark",
                description: Text("The live version of this transcript isn't saved with the meeting.")
            )
        case .ready(let result, let live):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.m) {
                    switch mode {
                    case .changes:
                        ForEach(result.lines) { line in
                            row(segment: line.segment, text: attributed(line.tokens))
                        }
                    case .live:
                        ForEach(live) { segment in row(segment: segment, text: AttributedString(segment.text)) }
                    case .improved:
                        ForEach(result.lines) { line in
                            row(segment: line.segment, text: AttributedString(line.segment.text))
                        }
                    }
                }
                .padding(Tokens.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(segment: TranscriptSegment, text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
            Text(segment.start.formattedTimestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(names[segment.speakerId] ?? segment.speakerId)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TranscriptView.speakerColor(speakerId: segment.speakerId, channel: segment.channel))
                Text(text)
                    .textSelection(.enabled)
            }
        }
    }

    /// The improved segment's words, with the ones the live transcript missed highlighted and the ones only it had struck through.
    private func attributed(_ tokens: [TranscriptDiff.Token]) -> AttributedString {
        func style(_ piece: inout AttributedString, _ kind: TranscriptDiff.Kind) {
            switch kind {
            case .same: break
            case .added: piece.backgroundColor = Color.accentColor.opacity(0.22)
            case .removed:
                piece.strikethroughStyle = .single
                piece.foregroundColor = .secondary
            }
        }
        var out = AttributedString()
        for (index, token) in tokens.enumerated() {
            var word = AttributedString(token.text)
            style(&word, token.kind)
            out += word
            guard index < tokens.count - 1 else { break }
            // A run of changed words reads as one block when the space between them is styled too.
            var space = AttributedString(" ")
            if tokens[index + 1].kind == token.kind { style(&space, token.kind) }
            out += space
        }
        return out
    }

    // MARK: - Loading

    private func load() async {
        let backup = folderURL.appendingPathComponent(RefinementRecord.liveBackupFilename)
        guard let data = try? Data(contentsOf: backup),
              let live = try? JSONDecoder().decode([TranscriptSegment].self, from: data) else {
            state = .unavailable
            return
        }
        let current = (try? await env.meetingStore.loadTranscript(for: meetingID)) ?? []
        if let meeting = try? await env.meetingStore.openMeeting(id: meetingID).meeting {
            names = Dictionary(meeting.participants.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        }
        let sortedLive = live.sorted { $0.start < $1.start }
        let result = await Task.detached(priority: .userInitiated) {
            TranscriptDiff.compare(live: sortedLive, improved: current)
        }.value
        state = .ready(result, live: sortedLive)
    }
}
