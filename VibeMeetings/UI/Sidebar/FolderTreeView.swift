import SwiftUI
import VMCore

struct FolderTreeView: View {
    let root: FolderNode?
    @Binding var selectedFolder: FolderNode?
    @Binding var selectedMeetingID: UUID?
    @Environment(AppEnvironment.self) private var env

    @State private var newFolderTarget: FolderNode?
    @State private var newFolderName: String = ""

    var body: some View {
        Group {
            if let root, !root.children.isEmpty || root.isMeeting {
                List(selection: $selectedMeetingID) {
                    OutlineGroup(root.children, id: \.id, children: \.optionalChildren) { node in
                        row(for: node)
                            .tag(node.meeting?.id)
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
                    newFolderTarget = root
                    newFolderName = "New Folder"
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New folder")

                Button {
                    NotificationCenter.default.post(name: .newMeetingRequested, object: nil)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .help("New meeting in selected folder")
            }
        }
        .sheet(item: $newFolderTarget) { target in
            NewFolderSheet(parent: target, name: $newFolderName) { name in
                Task {
                    _ = try? await env.meetingStore.createFolder(at: target, name: name)
                    newFolderTarget = nil
                }
            } onCancel: { newFolderTarget = nil }
        }
    }

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
}

private extension FolderNode {
    var optionalChildren: [FolderNode]? {
        children.isEmpty ? nil : children
    }
}

private struct NewFolderSheet: View {
    let parent: FolderNode
    @Binding var name: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New folder in \(parent.name)").font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Create") { onCreate(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
