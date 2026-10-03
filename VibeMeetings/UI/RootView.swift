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
                detail
                    .navigationTitle(detailTitle)
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if let ev = env.bannerCoordinator.currentSuggestion {
                        SuggestionBanner(
                            event: ev,
                            onStart: {
                                Task { await env.recordingService.start(event: ev) }
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
                    Label("Dashboard", systemImage: "house")
                }
                .help("Back to the dashboard")
                .disabled(selection.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Open on all meetings; if it is already showing a single
                    // meeting, switch to all meetings rather than closing it.
                    if showChatPanel && chatFocusedMeetingID == nil {
                        showChatPanel = false
                    } else {
                        chatFocusedMeetingID = nil
                        showChatPanel = true
                    }
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Ask questions across all meetings (⌥⌘I)")
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
            } else {
                // The library hasn't loaded (or couldn't be opened): never an empty, un-closable sheet.
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Your meetings folder isn't ready",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Vibe Meetings couldn't read its meetings folder. Check that it exists in Settings → General, then try again.")
                    )
                    Button("Close") { newMeetingRequest = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding()
                .frame(width: 420, height: 280)
            }
        }
        .sheet(item: $postRecording) { item in
            PostRecordingSheet(meetingID: item.meetingID, meetingFolderURL: item.folderURL)
        }
        .sheet(isPresented: Binding(
            get: { !env.hasCompletedOnboarding },
            set: { if !$0 { env.hasCompletedOnboarding = true } }
        )) {
            OnboardingFlowView()
        }
        .alert(
            env.presentedError?.title ?? "Something went wrong",
            isPresented: Binding(
                get: { env.presentedError != nil },
                set: { if !$0 { env.presentedError = nil } }
            ),
            presenting: env.presentedError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detail: some View {
        if selection.count > 1 {
            // Used to show an arbitrary one of the selected meetings.
            ContentUnavailableView(
                "\(selection.count) items selected",
                systemImage: "checkmark.circle",
                description: Text("Press Delete to move them to the Trash, or click one to open it.")
            )
        } else if let id = selection.single?.meetingID {
            MeetingDetailView(meetingID: id) { chatMeetingID in
                chatFocusedMeetingID = chatMeetingID
                showChatPanel = true
            }
            .id(id)
        } else if case .folder(let url)? = selection.single,
                  let node = env.folderTree?.node(at: url) {
            FolderOverviewView(folder: node) { meetingID in selection = [.meeting(meetingID)] }
                .id(url)
        } else {
            DashboardView { meetingID in
                selection = [.meeting(meetingID)]
            }
        }
    }

    private var detailTitle: String {
        guard let single = selection.single else { return selection.isEmpty ? "Dashboard" : "Selection" }
        switch single {
        case .meeting(let id):
            return env.folderTree?.meetingNode(id: id)?.meeting?.title ?? "Meeting"
        case .folder(let url):
            return env.folderTree?.node(at: url)?.name ?? "Folder"
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
            return root.node(at: url) ?? root
        case .meeting(let id):
            if let m = root.meetingNode(id: id), let parent = root.parent(of: m) {
                return parent
            }
            return root
        }
    }
}
