import SwiftUI
import VMCore
import VMStorage

/// Rename / delete / new-folder requests from anywhere in the library UI (the
/// sidebar's folders, the meeting list, a meeting's own page). One instance lives
/// in `RootView`, which attaches the sheets and alerts for it once.
@MainActor
@Observable
final class LibraryActions {
    var renameTarget: RenameTarget?
    var deleteTarget: DeleteTarget?
    var bulkDelete: [BulkDeleteItem]?
    /// Meetings waiting for a yes before their transcripts are improved.
    var improveRequest: TranscriptRefinementService.Plan?
    /// The folder a "New folder" sheet is creating inside.
    var newFolderParent: FolderNode?
    /// The folder whose icon is being chosen.
    var iconTarget: FolderNode?
    /// Bumped when an icon changes, so the sidebar re-reads them.
    var iconRevision = 0

    /// Called after meetings were moved to the Trash, so navigation can leave
    /// pages that no longer exist.
    @ObservationIgnored var onDeleted: (Set<UUID>) -> Void = { _ in }
}

// MARK: - Targets

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

// MARK: - Sheets and alerts

extension View {
    /// The new-folder and rename sheets and the delete confirmations for `library`.
    /// Attach once, high in the hierarchy.
    func libraryActionSheets(_ library: LibraryActions) -> some View {
        modifier(LibraryActionSheets(library: library))
    }
}

private struct LibraryActionSheets: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Bindable var library: LibraryActions

    private var improveTitle: String {
        let count = library.improveRequest?.meetings.count ?? 0
        return count == 1 ? "Improve this transcript?" : "Improve \(count) transcripts?"
    }

    private var improveMessage: String {
        guard let plan = library.improveRequest else { return "" }
        var text = "Each recording is transcribed again with a larger model, which usually finds a lot the live transcript missed. "
            + "The transcript is replaced, including any edits you've made; the original is kept so you can restore it. "
        if env.speakerDetectionEnabled { text += "Speakers are identified afterwards. " }
        text += "It takes a few minutes per hour of meeting, runs in the background, and pauses while you're recording."
        var skipped: [String] = []
        if plan.alreadyImproved > 0 { skipped.append("\(plan.alreadyImproved) already improved") }
        if plan.unavailable > 0 { skipped.append("\(plan.unavailable) without a usable recording") }
        if !skipped.isEmpty { text += " Skipping \(skipped.joined(separator: " and "))." }
        return text
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $library.newFolderParent) { target in
                NewFolderSheet(parent: target, isRoot: target.id == env.folderTree?.id) { name in
                    Task {
                        await env.attempt("create the folder") {
                            _ = try await env.meetingStore.createFolder(at: target, name: name)
                        }
                        // Refresh the tree before dismissing so the new folder is
                        // visible in the sidebar the moment the sheet closes.
                        await env.refreshFolderTree()
                        library.newFolderParent = nil
                    }
                } onCancel: { library.newFolderParent = nil }
            }
            .sheet(item: $library.iconTarget) { folder in
                FolderIconSheet(folder: folder) { library.iconRevision += 1 }
            }
            .sheet(item: $library.renameTarget) { target in
                RenameSheet(target: target) { newName in
                    Task {
                        switch target {
                        case .folder(let node):
                            await env.attempt("rename the folder") { try await env.meetingStore.renameFolder(node, to: newName) }
                        case .meeting(let id, _):
                            await env.attempt("rename the meeting") { try await env.meetingStore.renameMeeting(id: id, to: newName) }
                        }
                        await env.refreshFolderTree()
                        library.renameTarget = nil
                    }
                } onCancel: { library.renameTarget = nil }
            }
            .alert(item: $library.deleteTarget) { target in
                switch target {
                case .folder(let node):
                    return Alert(
                        title: Text("Delete \"\(node.name)\"?"),
                        message: Text("This folder and any meetings inside it will be moved to the Trash. You can restore them from there."),
                        primaryButton: .destructive(Text("Move to Trash")) {
                            Task {
                                await env.attempt("delete the folder") { try await env.meetingStore.deleteFolder(node) }
                                library.onDeleted(Set(node.allMeetings.map(\.id)))
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
                                library.onDeleted([id])
                                await env.refreshFolderTree()
                            }
                        },
                        secondaryButton: .cancel()
                    )
                }
            }
            .alert(
                "Delete \(library.bulkDelete?.count ?? 0) items?",
                isPresented: Binding(
                    get: { library.bulkDelete != nil },
                    set: { if !$0 { library.bulkDelete = nil } }
                )
            ) {
                Button("Move to Trash", role: .destructive) {
                    guard let items = library.bulkDelete else { return }
                    Task {
                        var deleted = Set<UUID>()
                        for item in items {
                            switch item {
                            case .folder(let node):
                                await env.attempt("delete “\(node.name)”") { try await env.meetingStore.deleteFolder(node) }
                                deleted.formUnion(node.allMeetings.map(\.id))
                            case .meeting(let id):
                                await env.attempt("delete a meeting") { try await env.meetingStore.deleteMeeting(id: id, deleteAudio: true) }
                                deleted.insert(id)
                            }
                        }
                        library.onDeleted(deleted)
                        await env.refreshFolderTree()
                    }
                }
                Button("Cancel", role: .cancel) { library.bulkDelete = nil }
            } message: {
                if let items = library.bulkDelete {
                    let meetings = items.filter { if case .meeting = $0 { return true }; return false }.count
                    let folders = items.filter { if case .folder = $0 { return true }; return false }.count
                    let parts = [
                        meetings > 0 ? "\(meetings) meeting\(meetings == 1 ? "" : "s")" : nil,
                        folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s")" : nil
                    ].compactMap { $0 }.joined(separator: " and ")
                    Text("\(parts.prefix(1).uppercased() + parts.dropFirst()) will be moved to the Trash, including any audio recordings. You can restore them from there.")
                }
            }
            .alert(
                improveTitle,
                isPresented: Binding(
                    get: { library.improveRequest != nil },
                    set: { if !$0 { library.improveRequest = nil } }
                )
            ) {
                Button("Improve") {
                    if let plan = library.improveRequest { env.refinementService.improve(plan.meetings, env: env) }
                    library.improveRequest = nil
                }
                Button("Cancel", role: .cancel) { library.improveRequest = nil }
            } message: {
                Text(improveMessage)
            }
    }
}

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

// MARK: - Menus

/// A folder picker that moves a meeting. The caller supplies the label (a plain
/// "Move to…" in a context menu, a folder chip on a meeting's page).
struct MoveToFolderMenu<Label: View>: View {
    let meetingID: UUID
    /// Runs after the move and the tree refresh (a meeting's page reloads its folder chip).
    var onMoved: () -> Void = {}
    @ViewBuilder var label: Label
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let root = env.folderTree {
            Menu {
                ForEach(root.allFolders, id: \.id) { folder in
                    // Full path, so two folders called "Weekly" can be told apart.
                    Button(folder.displayPath(relativeTo: env.rootURL)) {
                        Task {
                            await env.attempt("move the meeting") { try await env.meetingStore.moveMeeting(id: meetingID, to: folder) }
                            await env.refreshFolderTree()
                            onMoved()
                        }
                    }
                }
            } label: {
                label
            }
        }
    }
}

/// Right-click menu for a meeting row.
struct MeetingContextMenu: View {
    let meeting: Meeting
    let folderURL: URL
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryActions.self) private var library

    private var meetingID: UUID { meeting.id }

    var body: some View {
        Button("Rename…") { library.renameTarget = .meeting(id: meetingID, currentName: meeting.title) }
        MoveToFolderMenu(meetingID: meetingID) { Text("Move to…") }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folderURL]) }
        if meeting.hasAudio, meeting.endedAt != nil {
            Divider()
            ImproveTranscriptsMenuItem(targets: [(meeting, folderURL)])
        }
        Divider()
        Button("Delete…", role: .destructive) {
            library.deleteTarget = .meeting(id: meetingID, title: meeting.title, hasAudio: meeting.hasAudio)
        }
    }
}

/// "Improve Transcript…" for one or several meetings. Asks first (it replaces the transcripts), and skips the
/// ones already improved or without a recording to work from.
struct ImproveTranscriptsMenuItem: View {
    let targets: [(meeting: Meeting, folder: URL)]
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryActions.self) private var library

    var body: some View {
        let service = env.refinementService
        let plan = TranscriptRefinementService.plan(for: targets)
        let count = plan.meetings.count
        let busy = service.bulk != nil
        Button(title(count: count, total: targets.count, busy: busy), systemImage: "sparkles") {
            library.improveRequest = plan
        }
        .disabled(count == 0 || busy)
    }

    private func title(count: Int, total: Int, busy: Bool) -> String {
        if busy { return "Already Improving Transcripts…" }
        if total == 1 {
            if count == 1 { return "Improve Transcript…" }
            return env.refinementService.isImproved(targets[0].meeting.id) ? "Transcript Improved" : "Can't Improve Transcript"
        }
        if count == 0 { return "No Transcripts to Improve" }
        return "Improve \(count) Transcript\(count == 1 ? "" : "s")…"
    }
}

/// Right-click menu for a folder in the sidebar.
struct FolderContextMenu: View {
    let node: FolderNode
    @Environment(LibraryActions.self) private var library

    var body: some View {
        Button("New folder inside…") { library.newFolderParent = node }
        Button("Rename…") { library.renameTarget = .folder(node) }
        Button("Set Icon…") { library.iconTarget = node }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        let meetings = node.allMeetingNodes.compactMap { n in n.meeting.map { (meeting: $0, folder: n.url) } }
        if !meetings.isEmpty {
            Divider()
            ImproveTranscriptsMenuItem(targets: meetings)
        }
        Divider()
        Button("Delete…", role: .destructive) { library.deleteTarget = .folder(node) }
    }
}
