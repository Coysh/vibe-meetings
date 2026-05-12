import SwiftUI
import VMCore
import VMStorage

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: Set<SidebarSelection> = []
    @State private var newMeetingSheet = false
    @State private var preselectedEventID: String?
    @State private var showTriageSheet = false

    var body: some View {
        NavigationSplitView {
            FolderTreeView(
                root: env.folderTree,
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
                    if let id = selection.firstMeetingID {
                        MeetingDetailView(meetingID: id)
                            .id(id)
                    } else {
                        EmptyDetailView()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
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
                    if env.bannerCoordinator.micActiveSuggestion {
                        MicActiveBanner(
                            onStart: {
                                env.bannerCoordinator.dismissMicSuggestion()
                                newMeetingSheet = true
                            },
                            onDismiss: { env.bannerCoordinator.dismissMicSuggestion() }
                        )
                    }
                    if env.bannerCoordinator.meetingEndSuggestion {
                        MeetingEndBanner(
                            onStop: {
                                env.bannerCoordinator.dismissMeetingEnd()
                                if let controller = env.activeRecordingController {
                                    Task { await controller.stop() }
                                }
                            },
                            onKeep: { env.bannerCoordinator.dismissMeetingEnd() }
                        )
                    }
                    if let update = env.updateChecker.availableUpdate {
                        UpdateBanner(release: update, onDismiss: { env.updateChecker.dismissUpdate() })
                    }
                }
            }
        }
        .task {
            let env = self.env
            env.bannerCoordinator.setIsRecordingProvider {
                env.activeRecordingController?.state == .recording
            }
            env.bannerCoordinator.setActiveEventProvider {
                env.activeRecordingController?.linkedCalendarEvent
            }
            env.bannerCoordinator.start()
            await env.updateChecker.checkForUpdates()
            for await tree in env.meetingStore.tree {
                env.folderTree = tree
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTriageSheet = true
                } label: {
                    Label("Organise", systemImage: "tray.full")
                }
                .help("Organise untagged meetings")
            }
        }
        .sheet(isPresented: $showTriageSheet) {
            MeetingTriageView()
        }
        .sheet(isPresented: $newMeetingSheet, onDismiss: { preselectedEventID = nil }) {
            if let parent = resolvedParentForNewMeeting() {
                NewMeetingSheet(parentFolder: parent, preselectedEventID: preselectedEventID) { handle in
                    selection = [.meeting(handle.meeting.id)]
                    let c = RecordingController(env: env)
                    env.activeRecordingController = c
                    env.bannerCoordinator.recordingDidStart()
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
        guard let root = env.folderTree else { return nil }
        guard let sel = selection.single else { return root }
        switch sel {
        case .folder(let url):
            return findNode(at: url, in: root) ?? root
        case .meeting(let id):
            if let m = findMeetingNode(id: id, in: root),
               let parent = findParent(of: m, in: root) {
                return parent
            }
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

struct UpdateBanner: View {
    let release: UpdateChecker.GitHubRelease
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available: v\(release.version)")
                    .font(.callout.bold())
                if !release.body.isEmpty {
                    Text(release.body.prefix(120) + (release.body.count > 120 ? "…" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Link("Download", destination: release.htmlURL)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Dismiss", action: onDismiss)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.08))
    }
}
