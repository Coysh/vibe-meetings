import SwiftUI
import VMCore
import VMStorage

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: SidebarSelection?
    @State private var rootNode: FolderNode?
    @State private var newMeetingSheet = false
    @State private var preselectedEventID: String?

    var body: some View {
        NavigationSplitView {
            FolderTreeView(
                root: rootNode,
                selection: $selection
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
                    if let id = selection?.meetingID {
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
            if let parent = resolvedParentForNewMeeting() {
                NewMeetingSheet(parentFolder: parent, preselectedEventID: preselectedEventID) { handle in
                    selection = .meeting(handle.meeting.id)
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

    /// The folder a new meeting should be created inside, given the current
    /// sidebar selection: the selected folder, the selected meeting's parent,
    /// or root.
    private func resolvedParentForNewMeeting() -> FolderNode? {
        guard let root = rootNode else { return nil }
        switch selection {
        case .folder(let url):
            return findNode(at: url, in: root) ?? root
        case .meeting(let id):
            if let m = findMeetingNode(id: id, in: root),
               let parent = findParent(of: m, in: root) {
                return parent
            }
            return root
        case nil:
            return root
        }
    }
}

private func findNode(at url: URL, in node: FolderNode) -> FolderNode? {
    if node.url.standardizedFileURL == url.standardizedFileURL { return node }
    for child in node.children {
        if let hit = findNode(at: url, in: child) { return hit }
    }
    return nil
}

private func findMeetingNode(id: UUID, in node: FolderNode) -> FolderNode? {
    if node.isMeeting, node.meeting?.id == id { return node }
    for child in node.children {
        if let hit = findMeetingNode(id: id, in: child) { return hit }
    }
    return nil
}

private func findParent(of target: FolderNode, in node: FolderNode) -> FolderNode? {
    if node.children.contains(where: { $0.id == target.id }) { return node }
    for child in node.children {
        if let hit = findParent(of: target, in: child) { return hit }
    }
    return nil
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
