import SwiftUI

struct SummaryView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if markdown.isEmpty {
                    Text("No summary yet — stop the recording or click Generate Summary.")
                        .foregroundStyle(.secondary)
                } else {
                    let blocks = parseBlocks(bodyOnly(markdown))
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        renderBlock(block)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Block parsing

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// `indent` is the nesting depth (two spaces per level).
        case listItem(text: String, isCheckbox: Bool, isChecked: Bool, indent: Int)
        case numbered(number: String, text: String, indent: Int)
        case rule
    }

    private func parseBlocks(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        let lines = raw.components(separatedBy: "\n")
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let text = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraphBuffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = min(3, (line.prefix(while: { $0 == " " }).count) / 2)

            // Horizontal rule (was parsed *after* list items and silently dropped).
            if trimmed.wholeMatch(of: /^(---+|\*\*\*+|___+)$/) != nil {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            // Heading
            if let match = trimmed.wholeMatch(of: /^(#{1,4})\s+(.+)/) {
                flushParagraph()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
                continue
            }

            // Checkbox list item: - [ ] or - [x]
            if let match = trimmed.wholeMatch(of: /^-\s+\[([ xX])\]\s+(.+)/) {
                flushParagraph()
                let checked = match.1 != " "
                blocks.append(.listItem(text: String(match.2), isCheckbox: true, isChecked: checked, indent: indent))
                continue
            }

            // Regular list item: - text or * text
            if let match = trimmed.wholeMatch(of: /^[-*]\s+(.+)/) {
                flushParagraph()
                blocks.append(.listItem(text: String(match.1), isCheckbox: false, isChecked: false, indent: indent))
                continue
            }

            // Numbered list item: "1. text" or "1) text"
            if let match = trimmed.wholeMatch(of: /^(\d{1,3})[.)]\s+(.+)/) {
                flushParagraph()
                blocks.append(.numbered(number: String(match.1), text: String(match.2), indent: indent))
                continue
            }

            // Blank line → flush paragraph
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            paragraphBuffer.append(line)
        }
        flushParagraph()
        return blocks
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, level <= 2 ? 8 : 4)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .textSelection(.enabled)

        case .listItem(let text, let isCheckbox, let isChecked, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isCheckbox {
                    Image(systemName: isChecked ? "checkmark.square" : "square")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .accessibilityLabel(isChecked ? "Done" : "Not done")
                } else {
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                }
                Text(inlineMarkdown(text))
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case .numbered(let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(text))
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// Parse inline markdown (bold, italic, code) into an AttributedString.
    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    // MARK: - Front-matter stripping

    /// Strips the YAML front-matter so the renderer doesn't show it.
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
