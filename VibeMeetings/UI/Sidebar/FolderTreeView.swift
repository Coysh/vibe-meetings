import SwiftUI
import UniformTypeIdentifiers
import VMCore
import VMCalendar
import VMStorage

/// Sidebar view backed by the on-disk tree. Selection is a `SidebarSelection`
/// so folders and meetings share one binding; right-clicking any row opens a
/// context menu for create-subfolder / rename / delete.
struct FolderTreeView: View {
    let root: FolderNode?
    @Binding var selection: Set<SidebarSelection>
    @Environment(AppEnvironment.self) private var env

    @State private var newFolderTarget: FolderNode?
    @State private var renameTarget: RenameTarget?
    @State private var deleteTarget: DeleteTarget?
    @State private var bulkDeleteItems: [BulkDeleteItem]?
    @AppStorage("VibeMeetings.Sidebar.ViewMode") private var viewMode: SidebarViewMode = .recent
    @FocusState private var searchFocused: Bool
    @State private var isSearchingContent = false
    @State private var searchText = ""
    @State private var contentMatchIDs: Set<UUID> = []
    @State private var searchTask: Task<Void, Never>?
    @State private var upcomingEvents: [CalendarEvent] = []

    enum SidebarViewMode: String, CaseIterable {
        case folders = "Folders"
        case recent = "Recent"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search meetings…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .accessibilityLabel("Search meetings")
                    .onExitCommand { searchText = ""; contentMatchIDs.removeAll(); searchFocused = false }
                if isSearchingContent {
                    ProgressView().controlSize(.mini)
                        .help("Searching transcripts and summaries…")
                }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        contentMatchIDs.removeAll()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(8)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Picker("View", selection: $viewMode) {
                ForEach(SidebarViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Group {
                switch viewMode {
                case .folders:
                    folderListView
                case .recent:
                    recentListView
                }
            }
        }
        .onChange(of: searchText) {
            debounceContentSearch()
        }
        .task {
            // Keep "Upcoming" current: it used to load once, so the "Now" state
            // went stale and a meeting that had just started vanished.
            while !Task.isCancelled {
                upcomingEvents = await env.calendarService.upcomingEvents(within: 24 * 60 * 60)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: env.appRouter.pendingNewFolder) {
            if env.appRouter.pendingNewFolder {
                env.appRouter.pendingNewFolder = false
                requestNewFolder()
            }
        }
        .background {
            // ⌥⌘F — search the meeting list (⌘F stays "find in this transcript").
            Button("Search meetings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .hidden()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    env.appRouter.requestNewMeeting()
                } label: {
                    Label("New meeting", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Start a new meeting (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    requestNewFolder()
                } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
                .help("New folder (⇧⌘N)")
            }
        }
        .sheet(item: $newFolderTarget) { target in
            NewFolderSheet(parent: target, isRoot: target.id == root?.id) { name in
                Task {
                    await env.attempt("create the folder") {
                        _ = try await env.meetingStore.createFolder(at: target, name: name)
                    }
                    // Refresh the tree before dismissing so the new folder is
                    // visible in the sidebar the moment the sheet closes.
                    await env.refreshFolderTree()
                    newFolderTarget = nil
                }
            } onCancel: { newFolderTarget = nil }
        }
        .sheet(item: $renameTarget) { target in
            RenameSheet(target: target) { newName in
                Task {
                    switch target {
                    case .folder(let node):
                        await env.attempt("rename the folder") { try await env.meetingStore.renameFolder(node, to: newName) }
                    case .meeting(let id, _):
                        await env.attempt("rename the meeting") { try await env.meetingStore.renameMeeting(id: id, to: newName) }
                    }
                    await env.refreshFolderTree()
                    renameTarget = nil
                }
            } onCancel: { renameTarget = nil }
        }
        .alert(item: $deleteTarget) { target in
            switch target {
            case .folder(let node):
                return Alert(
                    title: Text("Delete \"\(node.name)\"?"),
                    message: Text("This folder and any meetings inside it will be moved to the Trash. You can restore them from there."),
                    primaryButton: .destructive(Text("Move to Trash")) {
                        Task {
                            await env.attempt("delete the folder") { try await env.meetingStore.deleteFolder(node) }
                            selection.remove(.folder(node.url))
                            await env.refreshFolderTree()
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .meeting(let id, let title, let hasAudio):
                return Alert(
                    title: Text("Delete \"\(title)\"?"),
                    message: Text(hasAudio
                                  ? "The meeting and its audio recording will be moved to the Trash. You can restore them from there."
                                  : "The meeting will be moved to the Trash. You can restore it from there."),
                    primaryButton: .destructive(Text("Move to Trash")) {
                        Task {
                            await env.attempt("delete the meeting") {
                                try await env.meetingStore.deleteMeeting(id: id, deleteAudio: hasAudio)
                            }
                            selection.remove(.meeting(id))
                            await env.refreshFolderTree()
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .alert(
            "Delete \(bulkDeleteItems?.count ?? 0) items?",
            isPresented: Binding(
                get: { bulkDeleteItems != nil },
                set: { if !$0 { bulkDeleteItems = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let items = bulkDeleteItems else { return }
                Task {
                    for item in items {
                        switch item {
                        case .folder(let node):
                            await env.attempt("delete “\(node.name)”") { try await env.meetingStore.deleteFolder(node) }
                        case .meeting(let id):
                            await env.attempt("delete a meeting") { try await env.meetingStore.deleteMeeting(id: id, deleteAudio: true) }
                        }
                    }
                    selection.removeAll()
                    await env.refreshFolderTree()
                }
            }
            Button("Cancel", role: .cancel) { bulkDeleteItems = nil }
        } message: {
            if let items = bulkDeleteItems {
                let meetings = items.filter { if case .meeting = $0 { return true }; return false }.count
                let folders = items.filter { if case .folder = $0 { return true }; return false }.count
                let parts = [
                    meetings > 0 ? "\(meetings) meeting\(meetings == 1 ? "" : "s")" : nil,
                    folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s")" : nil
                ].compactMap { $0 }.joined(separator: " and ")
                Text("\(parts.prefix(1).uppercased() + parts.dropFirst()) will be moved to the Trash, including any audio recordings. You can restore them from there.")
            }
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            requestBulkDelete()
        }
    }

    // MARK: - Search

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func meetingMatchesSearch(_ meeting: Meeting) -> Bool {
        guard isSearching else { return true }
        if meeting.title.lowercased().contains(query) { return true }
        if meeting.attendees?.contains(where: { $0.lowercased().contains(query) }) == true { return true }
        if meeting.org?.lowercased().contains(query) == true { return true }
        if contentMatchIDs.contains(meeting.id) { return true }
        return false
    }

    private func debounceContentSearch() {
        searchTask?.cancel()
        let currentQuery = query
        guard !currentQuery.isEmpty else {
            contentMatchIDs.removeAll()
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isSearchingContent = true
            let matches = await searchContent(query: currentQuery)
            guard !Task.isCancelled else { return }
            contentMatchIDs = matches
            isSearchingContent = false
        }
    }

    private func searchContent(query: String) async -> Set<UUID> {
        guard let root else { return [] }
        var matches = Set<UUID>()
        for meeting in root.allMeetings {
            if Task.isCancelled { break }
            // Already matched by title — skip disk read.
            if meeting.title.lowercased().contains(query) { continue }
            // Check the summary, then the transcript, on disk.
            if let summary = try? await env.meetingStore.loadSummary(for: meeting.id),
               summary.lowercased().contains(query) {
                matches.insert(meeting.id)
                continue
            }
            if let segments = try? await env.meetingStore.loadTranscript(for: meeting.id),
               segments.contains(where: { $0.text.lowercased().contains(query) }) {
                matches.insert(meeting.id)
            }
        }
        return matches
    }

    // MARK: - List views

    @ViewBuilder
    private var folderListView: some View {
        if let root, !root.children.isEmpty {
            if isSearching {
                // In search mode, show a flat filtered list instead of the tree.
                let matches = allMeetingsSorted.filter { meetingMatchesSearch($0.meeting) }
                if matches.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(selection: $selection) {
                        ForEach(matches, id: \.meeting.id) { item in
                            recentRow(meeting: item.meeting, folderName: item.folderName)
                                .tag(SidebarSelection.meeting(item.meeting.id))
                                .contextMenu {
                                    if let node = root.meetingNode(id: item.meeting.id) {
                                        contextMenu(for: node)
                                    }
                                }
                        }
                    }
                    .listStyle(.sidebar)
                }
            } else {
                List(selection: $selection) {
                    // Upcoming meetings from calendar.
                    let upcoming = futureCalendarEvents
                    if !upcoming.isEmpty {
                        Section {
                            ForEach(upcoming) { event in
                                upcomingEventRow(event: event)
                            }
                        } header: {
                            Text("Upcoming")
                        }
                    }

                    OutlineGroup(root.children, id: \.id, children: \.optionalChildren) { node in
                        row(for: node)
                            .tag(tag(for: node))
                            .contextMenu { contextMenu(for: node) }
                    }
                }
                .listStyle(.sidebar)
            }
        } else {
            ContentUnavailableView {
                Label("No meetings yet", systemImage: "folder")
            } description: {
                Text("Start a meeting, or create a folder to keep them in.")
            } actions: {
                Button("New meeting…") { env.appRouter.requestNewMeeting() }
                    .buttonStyle(.borderedProminent)
                Button("New folder…") { requestNewFolder() }
            }
        }
    }

    @ViewBuilder
    private var recentListView: some View {
        let meetings = allMeetingsSorted
        let filtered = isSearching
            ? meetings.filter { meetingMatchesSearch($0.meeting) }
            : meetings

        if isSearching && filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if meetings.isEmpty && !isSearching {
            ContentUnavailableView {
                Label("No meetings yet", systemImage: "waveform.badge.mic")
            } description: {
                Text("Start a meeting with ⌘N, or from the menu bar.")
            } actions: {
                Button("New meeting…") { env.appRouter.requestNewMeeting() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List(selection: $selection) {
                // Upcoming meetings from calendar (only when not searching).
                if !isSearching {
                    let upcoming = futureCalendarEvents
                    if !upcoming.isEmpty {
                        Section {
                            ForEach(upcoming) { event in
                                upcomingEventRow(event: event)
                            }
                        } header: {
                            Text("Upcoming")
                        }
                    }
                }

                // Date-grouped past meetings.
                let grouped = groupedByDate(filtered)
                ForEach(grouped, id: \.label) { group in
                    Section {
                        ForEach(group.items, id: \.meeting.id) { item in
                            recentRow(meeting: item.meeting, folderName: item.folderName)
                                .tag(SidebarSelection.meeting(item.meeting.id))
                                .contextMenu {
                                    if let root, let node = root.meetingNode(id: item.meeting.id) {
                                        contextMenu(for: node)
                                    }
                                }
                        }
                    } header: {
                        Text(group.label)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Upcoming calendar events

    private var futureCalendarEvents: [CalendarEvent] {
        // Includes a meeting that has already started — that is exactly when
        // you most want to record it — until it ends.
        let now = Date()
        return upcomingEvents
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    @ViewBuilder
    private func upcomingEventRow(event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.orange)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(event.title).lineLimit(1).font(.callout)
                        PlatformBadge(event: event)
                    }
                    HStack(spacing: 4) {
                        if event.startDate <= Date() {
                            Text("Now")
                                .font(.caption2.bold())
                                .foregroundStyle(.red)
                            Text("· until")
                                .foregroundStyle(.secondary)
                            Text(event.endDate, format: .dateTime.hour().minute())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(event.startDate, format: .dateTime.hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                if event.hasMeetingLink {
                    Button {
                        joinAndRecord(event: event)
                    } label: {
                        Label("Join & Record", systemImage: "video.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(event.platform.tint)
                    .controlSize(.small)
                }
                Button {
                    startRecording(event: event)
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func joinAndRecord(event: CalendarEvent) {
        Task { await env.recordingService.joinAndRecord(event: event) }
    }

    /// Starts recording straight away (like "Join & Record"), instead of opening a
    /// sheet — two similarly named buttons used to behave differently.
    private func startRecording(event: CalendarEvent) {
        Task { await env.recordingService.start(event: event) }
    }

    // MARK: - Date grouping

    private struct DateGroup {
        let label: String
        let items: [MeetingItem]
    }

    private func groupedByDate(_ items: [MeetingItem]) -> [DateGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfThisWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

        var today: [MeetingItem] = []
        var yesterday: [MeetingItem] = []
        var thisWeek: [MeetingItem] = []
        var earlier: [MeetingItem] = []

        for item in items {
            let date = item.meeting.startedAt
            if date >= startOfToday {
                today.append(item)
            } else if date >= startOfYesterday {
                yesterday.append(item)
            } else if date >= startOfThisWeek {
                thisWeek.append(item)
            } else {
                earlier.append(item)
            }
        }

        var groups: [DateGroup] = []
        if !today.isEmpty { groups.append(DateGroup(label: "Today", items: today)) }
        if !yesterday.isEmpty { groups.append(DateGroup(label: "Yesterday", items: yesterday)) }
        if !thisWeek.isEmpty { groups.append(DateGroup(label: "This Week", items: thisWeek)) }
        if !earlier.isEmpty { groups.append(DateGroup(label: "Earlier", items: earlier)) }
        return groups
    }

    // MARK: - Data collection

    private struct MeetingItem {
        let meeting: Meeting
        let folderName: String
    }

    private var allMeetingsSorted: [MeetingItem] {
        guard let root else { return [] }
        var items: [MeetingItem] = []
        collectMeetings(from: root, parentName: nil, into: &items)
        items.sort { $0.meeting.startedAt > $1.meeting.startedAt }
        return items
    }

    private func collectMeetings(from node: FolderNode, parentName: String?, into items: inout [MeetingItem]) {
        if node.isMeeting, let meeting = node.meeting {
            items.append(MeetingItem(meeting: meeting, folderName: parentName ?? ""))
        }
        for child in node.children {
            let name = node.isMeeting ? parentName : node.name
            collectMeetings(from: child, parentName: name, into: &items)
        }
    }

    @ViewBuilder
    private func recentRow(meeting: Meeting, folderName: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(meeting.startedAt, format: .dateTime.hour().minute())
                    if !folderName.isEmpty {
                        Text("·")
                        Text(folderName).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "waveform")
        }
        .draggable(meeting.id.uuidString)
        .accessibilityElement(children: .combine)
    }

    // MARK: - rows

    @ViewBuilder
    private func row(for node: FolderNode) -> some View {
        if node.isMeeting, let meeting = node.meeting {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title).lineLimit(1)
                    Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "waveform")
            }
            .draggable(meeting.id.uuidString)
        } else {
            Label(node.name, systemImage: "folder")
                .dropDestination(for: String.self) { items, _ in
                    guard let idStr = items.first, let id = UUID(uuidString: idStr) else { return false }
                    Task {
                        await env.attempt("move the meeting") { try await env.meetingStore.moveMeeting(id: id, to: node) }
                        await env.refreshFolderTree()
                    }
                    return true
                }
        }
    }

    private func tag(for node: FolderNode) -> SidebarSelection {
        if node.isMeeting, let meeting = node.meeting {
            return .meeting(meeting.id)
        }
        return .folder(node.url)
    }

    @ViewBuilder
    private func contextMenu(for node: FolderNode) -> some View {
        if node.isMeeting, let meeting = node.meeting {
            Button("Rename…") { renameTarget = .meeting(id: meeting.id, currentName: meeting.title) }
            if let root {
                let folders = root.allFolders
                if !folders.isEmpty {
                    Menu("Move to…") {
                        ForEach(folders, id: \.id) { folder in
                            // Full path, so two folders called "Weekly" can be told apart.
                            Button(folder.displayPath(relativeTo: env.rootURL)) {
                                Task {
                                    await env.attempt("move the meeting") { try await env.meetingStore.moveMeeting(id: meeting.id, to: folder) }
                                    await env.refreshFolderTree()
                                }
                            }
                        }
                    }
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Divider()
            Button("Delete…", role: .destructive) {
                deleteTarget = .meeting(id: meeting.id, title: meeting.title, hasAudio: meeting.hasAudio)
            }
        } else {
            Button("New folder inside…") { newFolderTarget = node }
            Button("Rename…") { renameTarget = .folder(node) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Divider()
            Button("Delete…", role: .destructive) { deleteTarget = .folder(node) }
        }
    }

    /// Resolve the "current folder" — the user's intent for where new
    /// folders / meetings should land:
    ///   - If a folder is selected, use it.
    ///   - If a meeting is selected, use its parent folder.
    ///   - Else the root.
    private func currentFolder() -> FolderNode? {
        guard let root else { return nil }
        guard let sel = selection.single else { return nil }
        switch sel {
        case .folder(let url):
            return root.node(at: url)
        case .meeting(let id):
            if let meetingNode = root.meetingNode(id: id) {
                return root.parent(of: meetingNode)
            }
            return nil
        }
    }

    /// New folder in the selected folder (or the selected meeting's folder), else at the top level.
    private func requestNewFolder() {
        guard let target = currentFolder() ?? root else { return }
        newFolderTarget = target
    }

    /// Build bulk-delete items from the current selection and present the
    /// confirmation alert.
    private func requestBulkDelete() {
        guard let root else { return }
        var items: [BulkDeleteItem] = []
        for sel in selection {
            switch sel {
            case .folder(let url):
                if let node = root.node(at: url) {
                    items.append(.folder(node))
                }
            case .meeting(let id):
                items.append(.meeting(id: id))
            }
        }
        guard !items.isEmpty else { return }
        bulkDeleteItems = items
    }
}

enum BulkDeleteItem: Identifiable {
    case folder(FolderNode)
    case meeting(id: UUID)

    var id: String {
        switch self {
        case .folder(let n): return "folder:\(n.id)"
        case .meeting(let id): return "meeting:\(id)"
        }
    }
}

private extension FolderNode {
    var optionalChildren: [FolderNode]? {
        children.isEmpty ? nil : children
    }
}

// MARK: - Sheets

private struct NewFolderSheet: View {
    let parent: FolderNode
    let isRoot: Bool
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String = "New Folder"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRoot ? "New top-level folder" : "New folder in \(parent.name)").font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Create") { onCreate(name) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

enum RenameTarget: Identifiable {
    case folder(FolderNode)
    case meeting(id: UUID, currentName: String)

    var id: String {
        switch self {
        case .folder(let n): return "folder:\(n.id)"
        case .meeting(let id, _): return "meeting:\(id)"
        }
    }

    var currentName: String {
        switch self {
        case .folder(let n): return n.name
        case .meeting(_, let name): return name
        }
    }

    var label: String {
        switch self {
        case .folder: return "Rename folder"
        case .meeting: return "Rename meeting"
        }
    }
}

private struct RenameSheet: View {
    let target: RenameTarget
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String

    init(target: RenameTarget, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._name = State(initialValue: target.currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.label).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Rename") { onConfirm(name) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || name == target.currentName)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

enum DeleteTarget: Identifiable {
    case folder(FolderNode)
    case meeting(id: UUID, title: String, hasAudio: Bool)

    var id: String {
        switch self {
        case .folder(let n): return "folder:\(n.id)"
        case .meeting(let id, _, _): return "meeting:\(id)"
        }
    }
}
