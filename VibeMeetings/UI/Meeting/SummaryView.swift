import SwiftUI

struct SummaryView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if markdown.isEmpty {
                    Text("No summary yet — stop the recording or click Generate Summary.")
                        .foregroundStyle(.secondary)
                } else {
                    if let attributed = try? AttributedString(markdown: bodyOnly(markdown)) {
                        Text(attributed)
                            .textSelection(.enabled)
                    } else {
                        Text(markdown).textSelection(.enabled)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Strips the YAML front-matter so SwiftUI's Markdown renderer doesn't show it.
    private func bodyOnly(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return raw }
        var body = lines.dropFirst()
        while let line = body.first, line.trimmingCharacters(in: .whitespaces) != "---" {
            body = body.dropFirst()
        }
        if !body.isEmpty { body = body.dropFirst() }
        return body.joined(separator: "\n")
    }
}
