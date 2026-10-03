import SwiftUI
import VMCore

/// Destination picker shared by the post-recording and Organise sheets.
///
/// Three explicit behaviours instead of one ambiguous "(keep in current
/// location)": file automatically, keep where it is, or pick a folder — plus a
/// field to create a new (optionally nested) folder.
struct FolderChoicePicker: View {
    @Binding var choice: FolderChoice
    @Binding var newFolderPath: String
    let folders: [FolderNode]
    let rootURL: URL
    /// The folder the app suggested, to mark it in the UI.
    let suggestedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Folder", selection: $choice) {
                Text("Automatic — by person or organisation").tag(FolderChoice.automatic)
                Text("Keep where it is").tag(FolderChoice.keep)
                Divider()
                ForEach(folders, id: \.url) { folder in
                    Text(folder.displayPath(relativeTo: rootURL)).tag(FolderChoice.folder(folder.url))
                }
            }
            .labelsHidden()
            .disabled(hasNewFolder)

            if hasNewFolder {
                Text("A new folder will be created and the meeting moved into it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .folder(let url) = choice, url == suggestedURL {
                Label("Suggested from the meeting's details", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
            } else if choice == .automatic {
                Text("Files into the person's or organisation's folder, creating it if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Or create a new folder, e.g. Clients/Acme", text: $newFolderPath)
                .textFieldStyle(.roundedBorder)
            Text("Use / to create nested folders.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var hasNewFolder: Bool {
        !newFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
