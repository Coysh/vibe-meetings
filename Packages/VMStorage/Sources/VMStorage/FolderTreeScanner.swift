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

    /// Scans a directory tree for bare `.md` files with YAML front-matter and imports them
    /// as proper meeting folders. Each markdown file gets wrapped into a subfolder containing
    /// `meeting.json` + `transcript.md`. The original file is moved (not copied).
    /// Returns the number of meetings imported.
    @discardableResult
    public static func importBareMarkdownFiles(in rootURL: URL) -> Int {
        let fm = FileManager.default
        var imported = 0

        func walk(_ dirURL: URL) {
            let entries = (try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            // Skip directories that are already meeting folders.
            let hasMeetingJSON = entries.contains { $0.lastPathComponent == MeetingFolder.metadataFilename }
            if hasMeetingJSON { return }

            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    walk(entry)
                } else if entry.pathExtension.lowercased() == "md" {
                    if let meeting = importMarkdownFile(at: entry, parentDir: dirURL, rootURL: rootURL) {
                        _ = meeting
                        imported += 1
                    }
                }
            }
        }

        walk(rootURL)
        return imported
    }

    /// Attempts to import a single markdown file by reading its YAML front-matter,
    /// creating a meeting folder, and moving the file as `transcript.md`.
    private static func importMarkdownFile(at fileURL: URL, parentDir: URL, rootURL: URL) -> Meeting? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let (header, _) = FrontMatterCodec.split(raw)
        guard !header.isEmpty else { return nil }

        // Require at least a title or date to consider this a meeting transcript.
        let title: String
        if let t = header["title"] as? String { title = t }
        else { title = fileURL.deletingPathExtension().lastPathComponent }

        // Parse date from front-matter or fall back to file modification date.
        let startedAt: Date
        if let dateStr = header["date"] as? String {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let timeStr = header["time"] as? String {
                df.dateFormat = "yyyy-MM-dd HH:mm"
                startedAt = df.date(from: "\(dateStr) \(timeStr)") ?? Date()
            } else {
                startedAt = df.date(from: dateStr) ?? Date()
            }
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            startedAt = (attrs?[.modificationDate] as? Date) ?? Date()
        }

        // Extract optional metadata.
        let meetingType: MeetingType?
        if let typeStr = header["type"] as? String {
            meetingType = MeetingType(rawValue: typeStr)
        } else {
            meetingType = nil
        }

        let org = header["org"] as? String
        let attendees = header["attendees"] as? [String]
        let labels = header["labels"] as? [String]

        // Build the meeting folder name.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let datePart = df.string(from: startedAt)
        let safeName = title.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = safeName.isEmpty ? datePart : "\(datePart) \(safeName)"

        // Create the meeting directory inside the same parent.
        var meetingDirURL = parentDir.appendingPathComponent(folderName)
        var n = 2
        while FileManager.default.fileExists(atPath: meetingDirURL.path) {
            meetingDirURL = parentDir.appendingPathComponent("\(folderName) (\(n))")
            n += 1
        }

        let relativePath = meetingDirURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")

        let meeting = Meeting(
            title: title,
            startedAt: startedAt,
            folderRelativePath: relativePath,
            transcriptionEngine: EngineRef(kind: "imported", version: "1"),
            modelId: "imported",
            sourceKind: .imported(originalFilename: fileURL.lastPathComponent),
            meetingType: meetingType,
            labels: labels,
            attendees: attendees,
            org: org
        )

        do {
            try FileManager.default.createDirectory(at: meetingDirURL, withIntermediateDirectories: true)
            let mf = MeetingFolder(url: meetingDirURL)
            try writeMeeting(meeting, to: mf.metadataURL)
            // Move the original markdown file as transcript.md.
            try FileManager.default.moveItem(at: fileURL, to: mf.transcriptURL)
            // Create empty segments file.
            try SegmentsFile.save([], to: mf.segmentsURL)
            return meeting
        } catch {
            print("[FolderTreeScanner] Failed to import \(fileURL.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Walks the tree to map `lowercased org name → parent folder URL`.
    /// Used to auto-route meetings with a given org into the correct folder.
    /// The most-recent meeting wins on conflict.
    public static func indexOrgFolders(in node: FolderNode) -> [String: URL] {
        struct Entry { let url: URL; let started: Date }
        var idx: [String: Entry] = [:]
        var stack: [FolderNode] = [node]
        while let n = stack.popLast() {
            if n.isMeeting, let m = n.meeting, let org = m.org, !org.isEmpty {
                let parent = n.url.deletingLastPathComponent()
                let key = org.lowercased()
                if let existing = idx[key], existing.started > m.startedAt { continue }
                idx[key] = Entry(url: parent, started: m.startedAt)
            } else {
                stack.append(contentsOf: n.children)
            }
        }
        return idx.mapValues { $0.url }
    }

    /// Walks the tree to map `lowercased person name → parent folder URL` for 1:1 meetings.
    /// Used to auto-route future 1:1s with the same person into the same parent folder.
    /// The most-recent meeting wins on conflict.
    public static func indexPersonFolders(in node: FolderNode) -> [String: URL] {
        struct Entry { let url: URL; let started: Date }
        var idx: [String: Entry] = [:]
        var stack: [FolderNode] = [node]
        while let n = stack.popLast() {
            if n.isMeeting, let m = n.meeting, let person = m.person, !person.isEmpty {
                let parent = n.url.deletingLastPathComponent()
                let key = person.lowercased()
                if let existing = idx[key], existing.started > m.startedAt { continue }
                idx[key] = Entry(url: parent, started: m.startedAt)
            } else {
                stack.append(contentsOf: n.children)
            }
        }
        return idx.mapValues { $0.url }
    }
}
