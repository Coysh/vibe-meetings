import SwiftUI
import VMCore

/// Sidebar view backed by the on-disk tree. Selection is a `SidebarSelection`
/// so folders and meetings share one binding; right-clicking any row opens a
/// context menu for create-subfolder / rename / delete.
struct FolderTreeView: View {
    let root: FolderNode?
    @Binding var selection: SidebarSelection?
    @Environment(AppEnvironment.self) private var env

    @State private var newFolderTarget: FolderNode?
    @State private var renameTarget: RenameTarget?
    @State private var deleteTarget: DeleteTarget?

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
                        Task { try? await env.meetingStore.deleteFolder(node) }
                    },
                    secondaryButton: .cancel()
                )
            case .meeting(let id, let title, let hasAudio):
                if hasAudio {
                    return Alert(
                        title: Text("Delete \"\(title)\"?"),
                        message: Text("Move the meeting (including its audio) to the Trash?"),
                        primaryButton: .destructive(Text("Delete with audio")) {
                            Task { try? await env.meetingStore.deleteMeeting(id: id, deleteAudio: true) }
                        },
                        secondaryButton: .cancel()
                    )
                } else {
                    return Alert(
                        title: Text("Delete \"\(title)\"?"),
                        message: Text("This meeting will be moved to the Trash."),
                        primaryButton: .destructive(Text("Move to Trash")) {
                            Task { try? await env.meetingStore.deleteMeeting(id: id, deleteAudio: false) }
                        },
                        secondaryButton: .cancel()
                    )
                }
            }
        }
    }

    // MARK: - rows

    @ViewBuilder
    private func row(for node: FolderNode) -> some View {
        if node.isMeeting, let meeting = node.meeting {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title).lineLimit(1)
                    Text(meeting.startedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "waveform")
            }
        } else {
            Label(node.name, systemImage: "folder")
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
        switch selection {
        case .folder(let url):
            return findNode(at: url, in: root)
        case .meeting(let id):
            if let meetingNode = findMeetingNode(id: id, in: root) {
                return findParent(of: meetingNode, in: root)
            }
            return nil
        case nil:
            return nil
        }
    }
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
