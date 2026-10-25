import SwiftUI
import VMCalendar
import VMCore
import VMStorage
import VMSummarization

/// A narrow sidebar (Home, All meetings, folders) beside a main pane. The
/// sidebar picks the pane's root page; opening a meeting pushes it on top with a
/// back button.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    /// Optional because a `List` selection is; it never goes back to nil (see `sidebarBinding`).
    @State private var sidebarItem: SidebarItem? = .home
    /// Meetings pushed over the root page. An array (not `NavigationPath`) so the top one can be read.
    @State private var path: [MeetingRoute] = []
    /// A meeting to push once the sidebar has switched to a page that lists it.
    @State private var pendingPush: UUID?
    /// One calendar refresh for every page that shows the schedule.
    @State private var upcomingEvents: [CalendarEvent] = []
    @State private var library = LibraryActions()
    @State private var newMeetingRequest: AppRouter.NewMeetingRequest?
    @State private var showTriageSheet = false
    @State private var showChatPanel = false
    @State private var chatFocusedMeetingID: UUID?
    @State private var postRecording: AppRouter.PostRecordingItem?

    private var currentItem: SidebarItem { sidebarItem ?? .home }

    private var sidebarBinding: Binding<SidebarItem?> {
        Binding(get: { sidebarItem }, set: { if let item = $0 { sidebarItem = item } })
    }

    var body: some View {
        observed
            .background {
                // ⌥⌘F — search the meeting list (⌘F stays "find in this transcript").
                Button("Search meetings") { focusSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .hidden()
            }
            .toolbar { toolbarContent }
            .inspector(isPresented: $showChatPanel) {
                MeetingChatView(focusedMeetingID: chatFocusedMeetingID)
                    .id(chatFocusedMeetingID)
                    .inspectorColumnWidth(min: 320, ideal: 400, max: 500)
            }
            .sheet(isPresented: $showTriageSheet) {
                MeetingTriageView()
            }
            .sheet(item: $newMeetingRequest) { request in
                newMeetingSheet(request)
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

    /// The split view with its state wiring (routing requests, tree changes, the calendar loop).
    private var observed: some View {
        splitView
            .environment(library)
            .libraryActionSheets(library)
            .onAppear {
                // Lets notification actions / the menu bar reopen this window
                // after it's been closed.
                env.presenter.openWindow = openWindow
                library.onDeleted = { ids in path.removeAll { ids.contains($0.id) } }
                consumeRouterRequests()
            }
            .task {
                while !Task.isCancelled {
                    await refreshUpcoming()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .onChange(of: sidebarItem) {
                // Leaving a page closes the meeting on top of it — unless a meeting is
                // what we're switching pages to show.
                path = pendingPush.map { [MeetingRoute(id: $0)] } ?? []
                pendingPush = nil
            }
            .onChange(of: env.folderTree.map { ObjectIdentifier($0) }) {
                // The folder on screen was renamed, moved or deleted.
                if case .folder(let url)? = sidebarItem, let root = env.folderTree, root.node(at: url) == nil {
                    sidebarItem = .allMeetings
                }
            }
            .onChange(of: env.appRouter.pendingNewMeeting) { consumeRouterRequests() }
            .onChange(of: env.appRouter.pendingPostRecording) { consumeRouterRequests() }
            .onChange(of: env.appRouter.selectMeetingID) { consumeRouterRequests() }
            .onChange(of: env.appRouter.showTemplatesPage) {
                if env.appRouter.showTemplatesPage {
                    env.appRouter.showTemplatesPage = false
                    sidebarItem = .templates
                }
            }
            .onChange(of: env.appRouter.pendingNewFolder) {
                if env.appRouter.pendingNewFolder {
                    env.appRouter.pendingNewFolder = false
                    library.newFolderParent = resolvedParentFolder()
                }
            }
            // A request queued behind an open sheet is picked up once it closes.
            .onChange(of: newMeetingRequest == nil) { consumeRouterRequests() }
            .onChange(of: postRecording == nil) { consumeRouterRequests() }
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(
                selection: sidebarBinding,
                onNewFolder: { library.newFolderParent = resolvedParentFolder() },
                onReselect: { item in
                    // Clicking the page you're on while a meeting is open goes back to it.
                    if item == currentItem { path = [] }
                },
                openMeetingID: path.last?.id,
                onOpenMeeting: { open(meetingID: $0) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            NavigationStack(path: $path) {
                rootPage
                    .navigationTitle(windowTitle)
                    .id(currentItem) // a fresh page (scroll, search) per sidebar item — not on the stack itself
                    .navigationDestination(for: MeetingRoute.self) { route in
                        MeetingDetailView(meetingID: route.id) { chatMeetingID in
                            chatFocusedMeetingID = chatMeetingID
                            showChatPanel = true
                        }
                        .id(route.id)
                        .navigationBarBackButtonHidden(true) // the page has its own back chevron (⌘[)
                        .navigationTitle(windowTitle)
                    }
            }
            // The page draws its own big title; the window title stays for the Window menu.
            .toolbar(removing: .title)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .safeAreaInset(edge: .top) { banners }
        }
    }

    private var banners: some View {
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Record / Stop from any page, without going Home or through a sheet.
        ToolbarItem(placement: .primaryAction) {
            RecordToolbarButton()
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

    @ViewBuilder
    private func newMeetingSheet(_ request: AppRouter.NewMeetingRequest) -> some View {
        if let parent = resolvedParentFolder() {
            NewMeetingSheet(parentFolder: parent, preselectedEventID: request.preselectEventID) { handle in
                open(meetingID: handle.meeting.id)
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

    // MARK: - Calendar

    /// A week ahead, so "Next up" can page through it.
    private func refreshUpcoming() async {
        upcomingEvents = await env.calendarService.upcomingEvents(within: 7 * 24 * 60 * 60)
    }

    // MARK: - Pages

    @ViewBuilder
    private var rootPage: some View {
        switch currentItem {
        case .home:
            DashboardView(upcoming: upcomingEvents) { open(meetingID: $0) }
        case .inbox:
            MeetingListView(scope: .inbox, upcoming: upcomingEvents, onRefreshCalendar: refreshCalendar) { open(meetingID: $0) }
        case .templates:
            TemplatesView()
        case .allMeetings:
            MeetingListView(scope: .all, upcoming: upcomingEvents, onRefreshCalendar: refreshCalendar) { open(meetingID: $0) }
        case .folder(let url):
            MeetingListView(scope: .folder(url), upcoming: upcomingEvents, onRefreshCalendar: refreshCalendar) { open(meetingID: $0) }
        }
    }

    private func refreshCalendar() {
        Task { await refreshUpcoming() }
    }

    private var windowTitle: String {
        if let route = path.last {
            return env.folderTree?.meetingNode(id: route.id)?.meeting?.title ?? "Meeting"
        }
        switch currentItem {
        case .home: return "Home"
        case .inbox: return "Inbox"
        case .templates: return "Templates"
        case .allMeetings: return "Meetings"
        case .folder(let url): return env.folderTree?.node(at: url)?.name ?? "Folder"
        }
    }

    // MARK: - Navigation

    /// Show a meeting. If the current page lists it, it's pushed over that page;
    /// otherwise the sidebar switches to All meetings first.
    private func open(meetingID id: UUID) {
        if currentPageLists(id) {
            path = [MeetingRoute(id: id)]
        } else {
            pendingPush = id
            sidebarItem = .allMeetings
        }
    }

    private func currentPageLists(_ id: UUID) -> Bool {
        switch currentItem {
        case .home, .allMeetings:
            return true
        case .templates:
            return false
        case .inbox:
            return env.folderTree?.children.contains { $0.isMeeting && $0.meeting?.id == id } == true
        case .folder(let url):
            return env.folderTree?.node(at: url)?.meetingNode(id: id) != nil
        }
    }

    private func focusSearch() {
        path = []
        if currentItem == .home { sidebarItem = .allMeetings }
        env.appRouter.pendingSearchFocus = true
    }

    /// Moves app-level requests (from notifications, the menu bar, the
    /// overlay or the recording service) into this window's local state.
    private func consumeRouterRequests() {
        let router = env.appRouter
        if let id = router.selectMeetingID {
            router.selectMeetingID = nil
            open(meetingID: id)
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

    /// The folder a new meeting or folder should be created inside, given where
    /// the user is: the open meeting's folder, the selected folder, or the root.
    private func resolvedParentFolder() -> FolderNode? {
        guard let root = env.folderTree else { return nil }
        if let route = path.last, let node = root.meetingNode(id: route.id), let parent = root.parent(of: node) {
            return parent
        }
        if case .folder(let url) = currentItem {
            return root.node(at: url) ?? root
        }
        return root
    }
}
