import SwiftUI
import VMCore

/// A folder's emoji ("project icon"), kept in a small hidden file inside the
/// folder itself. It goes where the folder goes — renamed, moved, or trashed —
/// and the library scan ignores it (hidden files are skipped).
enum FolderIcon {
    static let filename = ".vm-icon"

    static func read(in folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(filename), encoding: .utf8) else { return nil }
        return normalized(text)
    }

    /// `nil` (or an empty string) removes the icon.
    static func write(_ emoji: String?, in folder: URL) throws {
        let url = folder.appendingPathComponent(filename)
        guard let emoji = emoji.flatMap(normalized) else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try emoji.write(to: url, atomically: true, encoding: .utf8)
    }

    /// One visible character: whatever was typed or pasted, trimmed to its first grapheme.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map(String.init)
    }

    /// Icons for every folder under `root`, keyed by `FolderNode.id`. Reads one tiny file per folder.
    static func all(under root: FolderNode?) -> [String: String] {
        guard let root else { return [:] }
        var result: [String: String] = [:]
        for folder in root.allFolders {
            if let icon = read(in: folder.url) { result[folder.id] = icon }
        }
        return result
    }

    static let suggestions: [String] = [
        "📁", "🏢", "🏠", "💼", "📊", "📈", "💰", "🎯", "🚀", "💡", "🧪", "🛠️",
        "📣", "🤝", "👥", "🧑‍💻", "🎨", "📝", "📚", "🎓", "⚖️", "🏥", "🛒", "✈️",
        "🔒", "🔧", "🌍", "🌱", "⭐️", "🔥", "❤️", "🎉", "📅", "📞", "✉️", "🧭",
    ]
}

/// Pick an emoji for a folder: a grid of suggestions, or type any emoji.
struct FolderIconSheet: View {
    let folder: FolderNode
    let onChanged: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Icon for “\(folder.name)”").font(.headline)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(FolderIcon.suggestions, id: \.self) { emoji in
                    Button { choose(emoji) } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(width: 40, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .accessibilityLabel(emoji)
                }
            }

            HStack {
                TextField("Or type any emoji", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { choose(custom) }
                Button("Use") { choose(custom) }
                    .disabled(FolderIcon.normalized(custom) == nil)
            }

            HStack {
                Button("Remove Icon") { choose(nil) }
                    .disabled(FolderIcon.read(in: folder.url) == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 330)
    }

    private func choose(_ emoji: String?) {
        Task {
            await env.attempt("set the folder icon") {
                try FolderIcon.write(emoji, in: folder.url)
            }
            onChanged()
            dismiss()
        }
    }
}
