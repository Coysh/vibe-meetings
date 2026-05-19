import SwiftUI
import VMCore
import VMStorage
import VMSummarization

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: Set<SidebarSelection> = []
    @State private var newMeetingSheet = false
    @State private var preselectedEventID: String?
    @State private var showTriageSheet = false
    @State private var showChatPanel = false
    @State private var chatFocusedMeetingID: UUID?
    @State private var postRecordingMeetingID: UUID?
    @State private var postRecordingFolderURL: URL?

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
                    RecordingBarView(controller: controller, onStopped: {
                        handleRecordingStopped()
                    }, onNavigateToMeeting: {
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
                                preselectedEventID = ev.id
                                newMeetingSheet = true
                            },
                            onDismiss: { env.bannerCoordinator.dismiss(ev) }
                        )
                    }
                    if env.bannerCoordinator.micActiveSuggestion {
                        MicActiveBanner(
                            eventTitle: env.bannerCoordinator.micEventTitle,
                            appName: env.bannerCoordinator.micActiveAppName,
                            onStart: {
                                env.bannerCoordinator.dismissMicSuggestion()
                                newMeetingSheet = true
                            },
                            onDismiss: { env.bannerCoordinator.dismissMicSuggestion() }
                        )
                    }
                    if env.bannerCoordinator.meetingEndSuggestion {
                        MeetingEndBanner(
                            reason: env.bannerCoordinator.meetingEndReason,
                            onStop: {
                                env.bannerCoordinator.dismissMeetingEnd()
                                if let controller = env.activeRecordingController {
                                    Task {
                                        _ = await controller.stop()
                                        handleRecordingStopped()
                                    }
                                }
                            },
                            onKeep: { env.bannerCoordinator.dismissMeetingEnd() }
                        )
                    }
                    // Sparkle handles update UI natively.
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
            env.bannerCoordinator.setMeetingEndDetector(env.meetingEndDetector)
            env.bannerCoordinator.setNotificationProviders(
                meetingDetected: { env.notifyMeetingDetected },
                preMeetingReminder: { env.notifyPreMeetingReminder },
                reminderMinutes: { env.notifyReminderMinutes }
            )
            env.bannerCoordinator.start()
            // Sparkle handles update checks automatically on launch.
            for await tree in env.meetingStore.tree {
                env.folderTree = tree
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .newMeetingRequested)) { notification in
            if let eventID = notification.userInfo?["preselectedEventID"] as? String {
                preselectedEventID = eventID
            }
            newMeetingSheet = true
        }
        .sheet(isPresented: Binding(
            get: { postRecordingMeetingID != nil },
            set: { if !$0 { postRecordingMeetingID = nil; postRecordingFolderURL = nil } }
        )) {
            if let meetingID = postRecordingMeetingID,
               let folderURL = postRecordingFolderURL {
                PostRecordingSheet(meetingID: meetingID, meetingFolderURL: folderURL)
            }
        }
    }

    /// Captures the meeting info from the just-finished recording, clears the
    /// recording controller, presents the post-recording metadata sheet, and
    /// kicks off background summary generation automatically.
    private func handleRecordingStopped() {
        guard let controller = env.activeRecordingController,
              let handle = controller.meetingHandle else {
            env.activeRecordingController = nil
            return
        }
        let meetingID = handle.meeting.id
        let folderURL = handle.folderURL

        // Snapshot data needed for summary before clearing the controller.
        let segments = controller.liveSegments.map { seg in
            var s = seg
            s.isPartial = false
            return s
        }
        let meeting = handle.meeting
        let userNotes = controller.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : controller.notes

        env.activeRecordingController = nil
        postRecordingFolderURL = folderURL
        postRecordingMeetingID = meetingID

        // Auto-generate summary in the background (silently, no notification).
        if !segments.isEmpty {
            let modelId = env.activeSummarizationKind == OpenAIEngine.kind
                ? env.selectedOpenAIModelId
                : env.selectedOllamaModelId
            let prompt = env.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : env.customSystemPrompt

            env.summaryService.generate(
                meetingID: meetingID,
                meetingTitle: meeting.title,
                segments: segments,
                meeting: meeting,
                engine: env.summarizationEngine,
                modelId: modelId,
                userNotes: userNotes,
                customPrompt: prompt,
                store: env.meetingStore,
                silent: true
            )
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



