import SwiftUI
import VMCore

struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let participants: [Speaker]

    private var nameByID: [String: String] {
        Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.displayName) })
    }

    var body: some View {
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
