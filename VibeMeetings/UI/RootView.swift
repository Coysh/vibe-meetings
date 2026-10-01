import SwiftUI
import VMCore
import VMStorage
import VMSummarization

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Set<SidebarSelection> = []
    @State private var newMeetingRequest: AppRouter.NewMeetingRequest?
    @State private var showTriageSheet = false
    @State private var showChatPanel = false
    @State private var chatFocusedMeetingID: UUID?
    @State private var postRecording: AppRouter.PostRecordingItem?

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
                    RecordingBarView(controller: controller, onNavigateToMeeting: {
                        if let id = controller.meetingHandle?.meeting.id {
                            selection = [.meeting(id)]
                        }
                    })
                    Divider()
                }
                Group {
                    if let id = selection.firstMeetingID {
                        MeetingDetailView(meetingID: id) { chatMeetingID in
                            chatFocusedMeetingID = chatMeetingID
                            showChatPanel = true
                        }
                        .id(id)
                    } else {
                        DashboardView { meetingID in
                            selection = [.meeting(meetingID)]
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if let ev = env.bannerCoordinator.currentSuggestion {
                        SuggestionBanner(
                            event: ev,
                            onStart: {
                                Task { try? await env.recordingService.start(.event(ev)) }
                            },
                            onDismiss: { env.bannerCoordinator.dismiss(ev) }
                        )
                    } else if env.bannerCoordinator.micActiveSuggestion {
                        MicActiveBanner(
                            eventTitle: env.bannerCoordinator.micEventTitle,
                            appName: env.bannerCoordinator.micActiveAppName,
                            onStart: {
                                Task { await env.recordingService.startDetectedCall() }
                            },
                            onDismiss: { env.bannerCoordinator.dismissMicSuggestion() }
                        )
                    }
                    if env.bannerCoordinator.meetingEndSuggestion {
                        MeetingEndBanner(
                            reason: env.bannerCoordinator.meetingEndReason,
                            onStop: {
                                env.bannerCoordinator.dismissMeetingEnd()
                                Task { await env.recordingService.stop(reason: .meetingEnded) }
                            },
                            onKeep: { env.bannerCoordinator.dismissMeetingEnd() }
                        )
                    }
                    // Sparkle handles update UI natively.
                }
            }
        }
        .onAppear {
            // Lets notification actions / the menu bar reopen this window
            // after it's been closed.
            env.presenter.openWindow = openWindow
            consumeRouterRequests()
        }
        .onChange(of: env.appRouter.pendingNewMeeting) { consumeRouterRequests() }
        .onChange(of: env.appRouter.pendingPostRecording) { consumeRouterRequests() }
        .onChange(of: env.appRouter.selectMeetingID) { consumeRouterRequests() }
        // A request queued behind an open sheet is picked up once it closes.
        .onChange(of: newMeetingRequest == nil) { consumeRouterRequests() }
        .onChange(of: postRecording == nil) { consumeRouterRequests() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    selection = []
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Back to dashboard")
                .disabled(selection.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chatFocusedMeetingID = nil
                    showChatPanel.toggle()
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                }
                .help("Ask questions across all meetings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTriageSheet = true
                } label: {
                    Label("Organise", systemImage: "tray.full")
                }
                .help("Organise untagged meetings")
            }
        }
        .inspector(isPresented: $showChatPanel) {
            MeetingChatView(focusedMeetingID: chatFocusedMeetingID)
                .id(chatFocusedMeetingID)
                .inspectorColumnWidth(min: 320, ideal: 400, max: 500)
        }
        .sheet(isPresented: $showTriageSheet) {
            MeetingTriageView()
        }
        .sheet(item: $newMeetingRequest) { request in
            if let parent = resolvedParentForNewMeeting() {
                NewMeetingSheet(parentFolder: parent, preselectedEventID: request.preselectEventID) { handle in
                    selection = [.meeting(handle.meeting.id)]
                }
            }
        }
        .sheet(item: $postRecording) { item in
            PostRecordingSheet(meetingID: item.meetingID, meetingFolderURL: item.folderURL)
        }
    }

    /// Moves app-level requests (from notifications, the menu bar, the
    /// overlay or the recording service) into this window's local state.
    private func consumeRouterRequests() {
        let router = env.appRouter
        if let id = router.selectMeetingID {
            router.selectMeetingID = nil
            selection = [.meeting(id)]
        }
        // One sheet at a time: a finished recording's review takes priority.
        if let item = router.pendingPostRecording, newMeetingRequest == nil {
            router.pendingPostRecording = nil
            postRecording = item
        } else if let request = router.pendingNewMeeting, postRecording == nil {
            router.pendingNewMeeting = nil
            newMeetingRequest = request
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



