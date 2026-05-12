import SwiftUI
import UniformTypeIdentifiers
import VMCore

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

    var body: some View {
        Group {
            if let root, !root.children.isEmpty {
                List(selection: $selection) {
                    OutlineGroup(root.children, id: \.id, children: \.optionalChildren) { node in
                        row(for: node)
                            .tag(tag(for: node))
                            .contextMenu { contextMenu(for: node) }
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "folder",
                    description: Text("Create a folder, then start a meeting (⌘N).")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    newFolderTarget = currentFolder() ?? root
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New folder \(currentFolder().map { "in \($0.name)" } ?? "")")

                Button {
                    NotificationCenter.default.post(name: .newMeetingRequested, object: nil)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .help("New meeting in selected folder")
            }
        }
        .sheet(item: $newFolderTarget) { target in
            NewFolderSheet(parent: target) { name in
                Task {
                    _ = try? await env.meetingStore.createFolder(at: target, name: name)
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
                        try? await env.meetingStore.renameFolder(node, to: newName)
                    case .meeting(let id, _):
                        try? await env.meetingStore.renameMeeting(id: id, to: newName)
                    }
                    renameTarget = nil
                }
            } onCancel: { renameTarget = nil }
        }
        .alert(item: $deleteTarget) { target in
            switch target {
            case .folder(let node):
                return Alert(
                    title: Text("Delete \"\(node.name)\"?"),
                    message: Text("This folder and any meetings inside it will be moved to the Trash."),
                    primaryButton: .destructive(Text("Move to Trash")) {
                        Task {
                            do {
                                try await env.meetingStore.deleteFolder(node)
                            } catch {
                                print("[Delete] failed to delete folder \(node.name): \(error)")
                            }
                            selection.remove(.folder(node.url))
                            await env.refreshFolderTree()
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .meeting(let id, let title, let hasAudio):
                if hasAudio {
                    return Alert(
                        title: Text("Delete \"\(title)\"?"),
                        message: Text("Move the meeting (including its audio) to the Trash?"),
                        primaryButton: .destructive(Text("Delete with audio")) {
                            Task {
                                do {
                                    try await env.meetingStore.deleteMeeting(id: id, deleteAudio: true)
                                } catch {
                                    print("[Delete] failed to delete meeting \(id): \(error)")
                                }
                                selection.remove(.meeting(id))
                                await env.refreshFolderTree()
                            }
                        },
                        secondaryButton: .cancel()
                    )
                } else {
                    return Alert(
                        title: Text("Delete \"\(title)\"?"),
                        message: Text("This meeting will be moved to the Trash."),
                        primaryButton: .destructive(Text("Move to Trash")) {
                            Task {
                                do {
                                    try await env.meetingStore.deleteMeeting(id: id, deleteAudio: false)
                                } catch {
                                    print("[Delete] failed to delete meeting \(id): \(error)")
                                }
                                selection.remove(.meeting(id))
                                await env.refreshFolderTree()
                            }
                        },
                        secondaryButton: .cancel()
                    )
                }
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
                            try? await env.meetingStore.deleteFolder(node)
                        case .meeting(let id):
                            try? await env.meetingStore.deleteMeeting(id: id, deleteAudio: true)
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
                Text("Move \(parts) to the Trash? This cannot be undone.")
            }
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            requestBulkDelete()
        }
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
                        try? await env.meetingStore.moveMeeting(id: id, to: node)
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
                let folders = collectFolders(in: root)
                if !folders.isEmpty {
                    Menu("Move to…") {
                        ForEach(folders, id: \.id) { folder in
                            Button(folder.name) {
                                Task {
                                    try? await env.meetingStore.moveMeeting(id: meeting.id, to: folder)
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
            return findNode(at: url, in: root)
        case .meeting(let id):
            if let meetingNode = findMeetingNode(id: id, in: root) {
                return findParent(of: meetingNode, in: root)
            }
            return nil
        }
    }

    /// Build bulk-delete items from the current selection and present the
    /// confirmation alert.
    private func requestBulkDelete() {
        guard let root else { return }
        var items: [BulkDeleteItem] = []
        for sel in selection {
            switch sel {
            case .folder(let url):
                if let node = findNode(at: url, in: root) {
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

/// Collects all non-meeting folder nodes from the tree (for "Move to…" menu).
private func collectFolders(in node: FolderNode) -> [FolderNode] {
    var result: [FolderNode] = []
    if !node.isMeeting {
        result.append(node)
        for child in node.children {
            result.append(contentsOf: collectFolders(in: child))
        }
    }
    return result
}

private extension FolderNode {
    var optionalChildren: [FolderNode]? {
        children.isEmpty ? nil : children
    }
}

// MARK: - Tree lookup helpers

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

// MARK: - Sheets

private struct NewFolderSheet: View {
    let parent: FolderNode
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String = "New Folder"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New folder in \(parent.name)").font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.escape)
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
                Button("Cancel", action: onCancel).keyboardShortcut(.escape)
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
