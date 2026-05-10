import Foundation
import VMCore

public enum FolderTreeScanner {
    /// Recursively builds a `FolderNode` tree rooted at `root`. A directory becomes a
    /// "meeting" node iff it directly contains `meeting.json`; meeting folders are
    /// rendered as leaves (their children are not exposed in the sidebar).
    public static func scan(root: URL) -> FolderNode {
        scanDirectory(at: root)
    }

    private static func scanDirectory(at url: URL) -> FolderNode {
        let folder = MeetingFolder(url: url)
        if folder.isMeeting {
            let meeting = try? loadMeeting(from: folder.metadataURL)
            return FolderNode(
                url: url,
                name: url.lastPathComponent,
                isMeeting: true,
                meeting: meeting,
                children: []
            )
        }

        var children: [FolderNode] = []
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            children.append(scanDirectory(at: entry))
        }

        return FolderNode(
            url: url,
            name: url.lastPathComponent,
            isMeeting: false,
            meeting: nil,
            children: children
        )
    }

    public static func loadMeeting(from url: URL) throws -> Meeting {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: data)
    }

    public static func writeMeeting(_ meeting: Meeting, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meeting)
        try AtomicWriter.write(data, to: url)
    }

    /// Walks the tree to collect a `[UUID: URL]` index for fast `openMeeting(id:)` lookup.
    public static func indexMeetings(in node: FolderNode) -> [UUID: URL] {
        var idx: [UUID: URL] = [:]
        var stack: [FolderNode] = [node]
        while let n = stack.popLast() {
            if n.isMeeting, let m = n.meeting {
                idx[m.id] = n.url
            } else {
                stack.append(contentsOf: n.children)
            }
        }
        return idx
    }
}
