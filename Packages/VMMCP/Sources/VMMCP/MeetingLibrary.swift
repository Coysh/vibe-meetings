import Foundation
import VMCore
import VMStorage

/// Read-only view of a meetings folder for the MCP tools. Rescans on every call:
/// the library is small JSON files, and the app may be writing to it meanwhile
/// (all its writes go through `AtomicWriter`, so reads never see half a file).
public struct MeetingLibrary: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public struct Entry: Sendable {
        public let meeting: Meeting
        public let folderURL: URL
        /// The folder holding the meeting, relative to the root ("Clients/Acme"), or "/" at the root.
        public let folderPath: String
    }

    public struct Folder: Sendable {
        public let path: String
        public let meetingCount: Int
    }

    /// One line of transcript: consecutive final segments from one speaker.
    public struct Utterance: Sendable {
        public let start: TimeInterval
        public let speaker: String
        public let text: String
    }

    public var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Every meeting, newest first.
    public func entries() -> [Entry] {
        let tree = FolderTreeScanner.scan(root: root)
        return tree.allMeetingNodes
            .compactMap { node -> Entry? in
                guard let meeting = node.meeting else { return nil }
                return Entry(meeting: meeting, folderURL: node.url, folderPath: folderPath(ofMeetingAt: node.url))
            }
            .sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    public func entry(id: UUID) -> Entry? {
        let tree = FolderTreeScanner.scan(root: root)
        guard let node = tree.meetingNode(id: id), let meeting = node.meeting else { return nil }
        return Entry(meeting: meeting, folderURL: node.url, folderPath: folderPath(ofMeetingAt: node.url))
    }

    /// Every folder (the root included), with the number of meetings at or below it.
    public func folders() -> [Folder] {
        FolderTreeScanner.scan(root: root).allFolders.map {
            Folder(path: $0.displayPath(relativeTo: root), meetingCount: $0.allMeetings.count)
        }
    }

    public func summary(for entry: Entry) -> String? {
        readText(MeetingFolder(url: entry.folderURL).summaryURL)
    }

    public func notes(for entry: Entry) -> String? {
        readText(MeetingFolder(url: entry.folderURL).notesURL)
    }

    public func hasSummary(_ entry: Entry) -> Bool { nonEmptyFile(MeetingFolder(url: entry.folderURL).summaryURL) }
    public func hasNotes(_ entry: Entry) -> Bool { nonEmptyFile(MeetingFolder(url: entry.folderURL).notesURL) }

    /// The transcript as utterances, from `segments.json`. Empty when there is none
    /// (e.g. some imported meetings only have `transcript.md`; see `markdownTranscript`).
    public func utterances(for entry: Entry, maxLineLength: Int = 1500) -> [Utterance] {
        let url = MeetingFolder(url: entry.folderURL).segmentsURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let segments = try? JSONDecoder().decode([LiteSegment].self, from: data) else { return [] }

        let names = Dictionary(entry.meeting.participants.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var out: [Utterance] = []
        var current: (start: TimeInterval, speakerId: String, text: String)?
        for seg in segments where !seg.isPartial {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var c = current, c.speakerId == seg.speakerId, c.text.count + text.count < maxLineLength {
                c.text += " " + text
                current = c
            } else {
                if let c = current {
                    out.append(Utterance(start: c.start, speaker: names[c.speakerId] ?? c.speakerId.capitalized, text: c.text))
                }
                current = (seg.start, seg.speakerId, text)
            }
        }
        if let c = current {
            out.append(Utterance(start: c.start, speaker: names[c.speakerId] ?? c.speakerId.capitalized, text: c.text))
        }
        return out
    }

    /// The "Full transcript" section of `transcript.md`, with the callout markup stripped.
    public func markdownTranscript(for entry: Entry) -> String? {
        guard let md = readText(MeetingFolder(url: entry.folderURL).transcriptURL),
              let range = md.range(of: "## Full transcript") else { return nil }
        let lines = md[range.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var l = line
                if l.hasPrefix(">") { l = l.dropFirst() }
                if l.hasPrefix(" ") { l = l.dropFirst() }
                return l
            }
            .filter { !$0.hasPrefix("[!note]") && !$0.hasPrefix("Speaker labels are placeholders") }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - helpers

    private func folderPath(ofMeetingAt url: URL) -> String {
        let rootPath = root.path
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        guard parentPath.hasPrefix(rootPath) else { return "/" }
        let relative = String(parentPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "/" : relative
    }

    private func readText(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func nonEmptyFile(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
    }
}

/// `TranscriptSegment` without the per-word timings, which are most of the file
/// and which the tools never use.
private struct LiteSegment: Decodable {
    let speakerId: String
    let start: TimeInterval
    let text: String
    let isPartial: Bool
}
