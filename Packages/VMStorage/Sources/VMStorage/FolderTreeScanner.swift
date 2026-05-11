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

        // Sort: meetings by startedAt (newest first), folders alphabetically.
        children.sort { a, b in
            switch (a.meeting, b.meeting) {
            case (.some(let ma), .some(let mb)):
                return ma.startedAt > mb.startedAt
            case (.some, .none):
                return false  // folders before meetings
            case (.none, .some):
                return true
            case (.none, .none):
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
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

    /// Walks the tree to map `calendarSeriesID → parent folder URL`. The
    /// parent folder is the user's organisational folder for the series; new
    /// occurrences should land alongside the existing ones inside it. The
    /// most-recent occurrence wins on conflict.
    public static func indexSeries(in node: FolderNode) -> [String: URL] {
        struct Entry { let url: URL; let started: Date }
        var idx: [String: Entry] = [:]
        var stack: [FolderNode] = [node]
        while let n = stack.popLast() {
            if n.isMeeting, let m = n.meeting, let sid = m.calendarSeriesID, !sid.isEmpty {
                let parent = n.url.deletingLastPathComponent()
                if let existing = idx[sid], existing.started > m.startedAt { continue }
                idx[sid] = Entry(url: parent, started: m.startedAt)
            } else {
                stack.append(contentsOf: n.children)
            }
        }
        return idx.mapValues { $0.url }
    }
}
