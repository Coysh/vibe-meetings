import SwiftUI
import VMCore
import VMStorage

/// The narrow left column: Home, All meetings, the newest few meetings, and the folders ("projects")
/// meetings are filed in. The full lists of meetings are in the main pane.
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    var onNewFolder: () -> Void
    /// Tapping the item that's already selected, so its page can pop back to the list.
    var onReselect: (SidebarItem) -> Void
    /// The meeting open in the main pane, if any, so its row can show it.
    var openMeetingID: UUID?
    var onOpenMeeting: (UUID) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryActions.self) private var library
    @AppStorage("VibeMeetings.Sidebar.RecentExpanded") private var recentExpanded = true
    @State private var meetingCounts: [String: Int] = [:]
    @State private var folderIcons: [String: String] = [:]
    @State private var inboxCount = 0
    @State private var recent: [RecentMeeting] = []

    /// How many of the newest meetings the sidebar lists.
    private static let recentLimit = 8

    private struct RecentMeeting: Identifiable, Equatable {
        let id: UUID
        let title: String
        let startedAt: Date
    }

    private var folders: [FolderNode] {
        env.folderTree?.children.filter { !$0.isMeeting } ?? []
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                navRow("Home", systemImage: "house", item: .home)
                navRow("Inbox", systemImage: "tray", item: .inbox, badge: inboxCount)
                navRow("All meetings", systemImage: "rectangle.stack", item: .allMeetings)
            }

            if !recent.isEmpty {
                Section(isExpanded: $recentExpanded) {
                    ForEach(recent) { recentRow($0) }
                    Button {
                        selection = .allMeetings
                        onReselect(.allMeetings)
                    } label: {
                        Label("Show all", systemImage: "arrow.right").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                } header: {
                    Text("Recent")
                }
            }

            Section {
                OutlineGroup(folders, id: \.id, children: \.subfolders) { node in
                    folderRow(node)
                }
                Button(action: onNewFolder) {
                    Label("New folder", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .help("New folder (⇧⌘N)")
            } header: {
                Text("Folders")
            }

            Section {
                navRow("Templates", systemImage: "sparkles", item: .templates)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Tokens.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .task(id: TaskKey(tree: env.folderTree.map { ObjectIdentifier($0) }, icons: library.iconRevision)) { recompute() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Vibe Meetings")
                .font(.system(.title3, design: .serif).weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Text(versionString)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        return version.isEmpty ? "" : "v\(version)"
    }

    // MARK: - Rows

    private func navRow(_ title: String, systemImage: String, item: SidebarItem, badge: Int = 0) -> some View {
        Label(title, systemImage: systemImage)
            .badge(badge)
            .tag(item)
            .simultaneousGesture(TapGesture().onEnded { onReselect(item) })
    }

    /// A meeting in the Recent list. Not a sidebar selection (that picks the page on the right); it opens the
    /// meeting on top of whatever page is showing, and marks itself while that meeting is open or recording.
    private func recentRow(_ meeting: RecentMeeting) -> some View {
        let isOpen = meeting.id == openMeetingID
        let isRecording = meeting.id == env.activeRecordingController?.meetingHandle?.meeting.id
        let title = meeting.title.isEmpty ? "Untitled meeting" : meeting.title
        let when = Self.when(meeting.startedAt)
        return Button {
            onOpenMeeting(meeting.id)
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(when).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            } icon: {
                // The dot keeps its space when it's not shown, so titles line up.
                Circle().fill(isRecording ? Color.red : Color.clear).frame(width: 7, height: 7)
            }
            .fontWeight(isOpen ? .semibold : .regular)
            .padding(.vertical, 1)
            .background(isOpen ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .accessibilityLabel("\(title), \(when)\(isRecording ? ", recording" : "")")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    /// Today as a time, the past week as a weekday, older as a date.
    private static func when(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    @ViewBuilder
    private func folderRow(_ node: FolderNode) -> some View {
        let item = SidebarItem.folder(node.url)
        Label {
            Text(node.name)
        } icon: {
            if let emoji = folderIcons[node.id] {
                Text(emoji)
            } else {
                Image(systemName: "folder")
            }
        }
            .badge(meetingCounts[node.id] ?? 0)
            .tag(item)
            .simultaneousGesture(TapGesture().onEnded { onReselect(item) })
            .contextMenu { FolderContextMenu(node: node) }
            .dropDestination(for: String.self) { items, _ in
                guard let idStr = items.first, let id = UUID(uuidString: idStr) else { return false }
                Task {
                    await env.attempt("move the meeting") { try await env.meetingStore.moveMeeting(id: id, to: node) }
                    await env.refreshFolderTree()
                }
                return true
            }
    }

    private struct TaskKey: Equatable {
        let tree: ObjectIdentifier?
        let icons: Int
    }

    /// Meetings per folder (including subfolders), icons, the Inbox count and the newest meetings —
    /// worked out once per tree change rather than per row render.
    private func recompute() {
        guard let root = env.folderTree else {
            meetingCounts = [:]; folderIcons = [:]; inboxCount = 0; recent = []
            return
        }
        var counts: [String: Int] = [:]
        for folder in root.allFolders {
            counts[folder.id] = folder.allMeetingNodes.count
        }
        meetingCounts = counts
        folderIcons = FolderIcon.all(under: root)
        inboxCount = root.children.filter { $0.isMeeting }.count
        recent = root.allMeetingNodes
            .compactMap(\.meeting)
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(Self.recentLimit)
            .map { RecentMeeting(id: $0.id, title: $0.title, startedAt: $0.startedAt) }
    }
}

private extension FolderNode {
    /// Sub-folders only (meetings are listed in the main pane), `nil` when there are none.
    var subfolders: [FolderNode]? {
        let folders = children.filter { !$0.isMeeting }
        return folders.isEmpty ? nil : folders
    }
}
