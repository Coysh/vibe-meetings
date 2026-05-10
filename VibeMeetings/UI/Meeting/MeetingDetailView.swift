import SwiftUI
import VMCore
import VMStorage

struct MeetingDetailView: View {
    let meetingID: UUID
    @Environment(AppEnvironment.self) private var env
    @State private var handle: MeetingHandle?
    @State private var segments: [TranscriptSegment] = []
    @State private var summary: String = ""
    @State private var selectedTab: Tab = .transcript

    enum Tab: String, CaseIterable, Identifiable {
        case transcript, summary, audio
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let handle {
                header(meeting: handle.meeting)
                Divider()
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch selectedTab {
                    case .transcript:
                        TranscriptView(segments: segments, participants: handle.meeting.participants)
                    case .summary:
                        SummaryView(markdown: summary)
                    case .audio:
                        AudioPlaybackView(audioURL: handle.audioURL)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: meetingID) {
            await load()
        }
    }

    @ViewBuilder
    private func header(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title).font(.title2).bold()
            HStack(spacing: 16) {
                Label(meeting.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                if let dur = meeting.duration {
                    Label(dur.formattedDuration, systemImage: "clock")
                }
                Label(meeting.modelId, systemImage: "cpu")
                Label(meeting.transcriptionEngine.kind, systemImage: "waveform")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func load() async {
        do {
            let h = try await env.meetingStore.openMeeting(id: meetingID)
            self.handle = h
            self.segments = (try? await env.meetingStore.loadTranscript(for: meetingID)) ?? []
            self.summary = (try? await env.meetingStore.loadSummary(for: meetingID)) ?? ""
        } catch {
            print("Could not load meeting \(meetingID): \(error)")
        }
    }
}
