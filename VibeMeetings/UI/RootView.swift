import SwiftUI
import VMCore
import VMStorage

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selectedFolder: FolderNode?
    @State private var selectedMeetingID: UUID?
    @State private var rootNode: FolderNode?
    @State private var newMeetingSheet = false
    @State private var preselectedEventID: String?

    var body: some View {
        NavigationSplitView {
            FolderTreeView(
                root: rootNode,
                selectedFolder: $selectedFolder,
                selectedMeetingID: $selectedMeetingID
            )
            .navigationTitle(env.rootURL.lastPathComponent)
            .frame(minWidth: 240)
        } detail: {
            VStack(spacing: 0) {
                if let controller = env.activeRecordingController {
                    RecordingBarView(controller: controller)
                    Divider()
                }
                Group {
                    if let id = selectedMeetingID {
                        MeetingDetailView(meetingID: id)
                            .id(id)
                    } else {
                        EmptyDetailView()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let ev = env.bannerCoordinator.currentSuggestion {
                    SuggestionBanner(
                        event: ev,
                        onStart: {
                            preselectedEventID = ev.id
                            newMeetingSheet = true
                        },
                        onDismiss: { env.bannerCoordinator.dismiss(ev) }
                    )
                }
            }
        }
        .task {
            let env = self.env
            env.bannerCoordinator.setIsRecordingProvider {
                env.activeRecordingController?.state == .recording
            }
            env.bannerCoordinator.start()
            for await tree in env.meetingStore.tree {
                rootNode = tree
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                PrivacyBadgeView()
            }
        }
        .sheet(isPresented: $newMeetingSheet, onDismiss: { preselectedEventID = nil }) {
            if let parent = selectedFolder ?? rootNode {
                NewMeetingSheet(parentFolder: parent, preselectedEventID: preselectedEventID) { handle in
                    selectedMeetingID = handle.meeting.id
                    let c = RecordingController(env: env)
                    env.activeRecordingController = c
                    Task { await c.start(handle: handle) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMeetingRequested)) { _ in
            newMeetingSheet = true
        }
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select a meeting, or press ⌘N to start a new one.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PrivacyBadgeView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("This app never sends data to the cloud. Audio, transcripts, and summaries stay on this Mac.")
    }

    private var color: Color {
        switch env.privacyState {
        case .localOnly: return .green
        case .downloadingModel: return .yellow
        }
    }

    private var label: String {
        switch env.privacyState {
        case .localOnly: return "Local-only"
        case .downloadingModel(let p): return "Downloading model — \(Int(p * 100))%"
        }
    }
}
