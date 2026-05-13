import Foundation
import VMCore

public actor FilesystemMeetingStore: MeetingStore {
    public nonisolated let rootURL: URL

    private var cachedTree: FolderNode
    private var meetingIndex: [UUID: URL] = [:]
    private var seriesIndex: [String: URL] = [:]   // calendarSeriesID → parent folder URL
    private var personIndex: [String: URL] = [:]   // lowercased person name → parent folder URL
    private var orgIndex: [String: URL] = [:]      // lowercased org name → folder URL
    private var watcher: FolderWatcher?
    private var subscribers: [UUID: AsyncStream<FolderNode>.Continuation] = [:]

    public init(rootURL: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootURL.path) {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        self.rootURL = rootURL

        // Auto-import bare .md files with YAML front-matter on first scan.
        let imported = FolderTreeScanner.importBareMarkdownFiles(in: rootURL)
        if imported > 0 {
            print("[MeetingStore] Imported \(imported) bare markdown file(s) as meetings")
        }

        self.cachedTree = FolderTreeScanner.scan(root: rootURL)
        self.meetingIndex = FolderTreeScanner.indexMeetings(in: self.cachedTree)
        self.seriesIndex = FolderTreeScanner.indexSeries(in: self.cachedTree)
        self.personIndex = FolderTreeScanner.indexPersonFolders(in: self.cachedTree)
        self.orgIndex = FolderTreeScanner.indexOrgFolders(in: self.cachedTree)
        Task { await self.startWatching() }
    }

    private func startWatching() {
        let w = FolderWatcher(url: rootURL) { [weak self] in
            Task { await self?.refreshFromDisk() }
        }
        w.start()
        watcher = w
    }

    public nonisolated var tree: AsyncStream<FolderNode> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    private func subscribe(id: UUID, continuation: AsyncStream<FolderNode>.Continuation) {
        subscribers[id] = continuation
        continuation.yield(cachedTree)
    }

    private func unsubscribe(id: UUID) {
        subscribers[id] = nil
    }

    public func currentTree() -> FolderNode { cachedTree }

    private func refreshFromDisk() {
        cachedTree = FolderTreeScanner.scan(root: rootURL)
        meetingIndex = FolderTreeScanner.indexMeetings(in: cachedTree)
        seriesIndex = FolderTreeScanner.indexSeries(in: cachedTree)
        personIndex = FolderTreeScanner.indexPersonFolders(in: cachedTree)
        orgIndex = FolderTreeScanner.indexOrgFolders(in: cachedTree)
        for (_, c) in subscribers { c.yield(cachedTree) }
    }

    public func folderForSeries(_ seriesID: String) async -> FolderNode? {
        guard let url = seriesIndex[seriesID] else { return nil }
        return findNode(at: url, in: cachedTree)
    }

    public func folderForPerson(_ name: String) async -> FolderNode? {
        if let url = personIndex[name.lowercased()] {
            return findNode(at: url, in: cachedTree)
        }
        // Fallback: search by folder name.
        if let url = findFolderByName(matching: name, in: cachedTree) {
            return findNode(at: url, in: cachedTree)
        }
        return nil
    }

    public func folderForOrg(_ name: String) async -> FolderNode? {
        if let url = orgIndex[name.lowercased()] {
            return findNode(at: url, in: cachedTree)
        }
        // Fallback: search by folder name.
        if let url = findFolderByName(matching: name, in: cachedTree) {
            return findNode(at: url, in: cachedTree)
        }
        return nil
    }

    private func findNode(at url: URL, in node: FolderNode) -> FolderNode? {
        if node.url.standardizedFileURL == url.standardizedFileURL { return node }
        for child in node.children {
            if let hit = findNode(at: url, in: child) { return hit }
        }
        return nil
    }

    private func broadcast() { refreshFromDisk() }

    // MARK: - Meeting CRUD

    public func createMeeting(in folder: FolderNode, draft: MeetingDraft) async throws -> MeetingHandle {
        let parent = folder.url

        // Build a temporary Meeting to compute the folder name using the
        // full yyyy-MM-dd-name-title format (needs attendees/person info).
        let tempMeeting = Meeting(
            title: draft.title,
            startedAt: draft.startedAt,
            folderRelativePath: "",
            transcriptionEngine: draft.transcriptionEngine,
            modelId: draft.modelId,
            meetingType: draft.meetingType,
            attendees: draft.attendees,
            org: draft.org
        )
        let folderName = meetingFolderName(for: tempMeeting)
        let meetingURL = uniqueURL(parent: parent, base: folderName)
        let relativePath = meetingURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")

        let meeting = Meeting(
            title: draft.title,
            startedAt: draft.startedAt,
            folderRelativePath: relativePath,
            transcriptionEngine: draft.transcriptionEngine,
            summarizationEngine: draft.summarizationEngine,
            modelId: draft.modelId,
            language: draft.language,
            sourceKind: draft.sourceKind,
            calendarEventID: draft.calendarEventID,
            calendarSeriesID: draft.calendarSeriesID,
            meetingPlatform: draft.meetingPlatform,
            calendarTitle: draft.calendarSeriesID != nil ? draft.title : nil,
            meetingType: draft.meetingType,
            labels: draft.labels,
            attendees: draft.attendees,
            org: draft.org
        )

        try AtomicWriter.createDirectory(at: meetingURL) { tmp in
            let mfTmp = MeetingFolder(url: tmp)
            try FolderTreeScanner.writeMeeting(meeting, to: mfTmp.metadataURL)
            try Data().write(to: mfTmp.transcriptURL)
            try SegmentsFile.save([], to: mfTmp.segmentsURL)
        }

        broadcast()
        return makeHandle(meeting: meeting, folderURL: meetingURL)
    }

    public func openMeeting(id: UUID) async throws -> MeetingHandle {
        guard let url = meetingIndex[id] else {
            throw MeetingStoreError.meetingNotFound(id)
        }
        let mf = MeetingFolder(url: url)
        let meeting = try FolderTreeScanner.loadMeeting(from: mf.metadataURL)
        return makeHandle(meeting: meeting, folderURL: url)
    }

    public func renameMeeting(id: UUID, to title: String) async throws {
        guard let url = meetingIndex[id] else {
            throw MeetingStoreError.meetingNotFound(id)
        }
        let mf = MeetingFolder(url: url)
        var meeting = try FolderTreeScanner.loadMeeting(from: mf.metadataURL)
        meeting.title = title
        try FolderTreeScanner.writeMeeting(meeting, to: mf.metadataURL)

        let parent = url.deletingLastPathComponent()
        let newName = meetingFolderName(for: meeting)
        if newName != url.lastPathComponent {
            let dest = uniqueURL(parent: parent, base: newName)
            try FileManager.default.moveItem(at: url, to: dest)
            meetingIndex[id] = dest
        }
        broadcast()
    }

    public func moveMeeting(id: UUID, to folder: FolderNode) async throws {
        guard let url = meetingIndex[id] else {
            throw MeetingStoreError.meetingNotFound(id)
        }
        let dest = uniqueURL(parent: folder.url, base: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        meetingIndex[id] = dest
        broadcast()
    }

    public func updateMeeting(_ meeting: Meeting) async throws {
        guard var url = meetingIndex[meeting.id] else {
            throw MeetingStoreError.meetingNotFound(meeting.id)
        }

        // Write updated metadata first (so folder rename picks up new fields).
        let mf = MeetingFolder(url: url)
        try FolderTreeScanner.writeMeeting(meeting, to: mf.metadataURL)

        // Re-render transcript.md with current summary + notes content.
        let segments = try SegmentsFile.load(from: mf.segmentsURL)
        let summary = loadBodyIfExists(mf.summaryURL)
        let notes = loadBodyIfExists(mf.notesURL)
        let md = MarkdownTranscriptWriter.render(
            meeting: meeting,
            segments: segments,
            summary: summary,
            notes: notes
        )
        try AtomicWriter.write(Data(md.utf8), to: mf.transcriptURL)

        // Auto-move based on person (for 1:1s) or org.
        // For 1:1 meetings, person folder takes priority over org folder.
        let currentParent = url.deletingLastPathComponent()
        var targetFolder: URL?

        // 1. Person-based routing for 1:1s — highest priority.
        if let person = meeting.person, !person.isEmpty {
            if let personFolder = personIndex[person.lowercased()] {
                targetFolder = personFolder
            } else {
                targetFolder = findFolderByName(matching: person, in: cachedTree)
            }
        }

        // 2. Org-based routing (only if person routing didn't match).
        if targetFolder == nil, let org = meeting.org, !org.isEmpty {
            if let orgFolder = orgIndex[org.lowercased()] {
                targetFolder = orgFolder
            } else {
                targetFolder = findFolderByName(matching: org, in: cachedTree)
            }
        }

        // Move if we found a target that differs from the current parent.
        if let targetFolder,
           targetFolder.standardizedFileURL != currentParent.standardizedFileURL {
            let dest = uniqueURL(parent: targetFolder, base: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            url = dest
            meetingIndex[meeting.id] = dest
            try updateFolderRelativePath(for: meeting, at: dest)
        }

        // Rename the folder to match updated metadata (person name, title, etc.).
        let expectedName = meetingFolderName(for: meeting)
        let parent = url.deletingLastPathComponent()
        if expectedName != url.lastPathComponent {
            let dest = uniqueURL(parent: parent, base: expectedName)
            try FileManager.default.moveItem(at: url, to: dest)
            meetingIndex[meeting.id] = dest
            try updateFolderRelativePath(for: meeting, at: dest)
        }

        broadcast()
    }

    public func deleteMeeting(id: UUID, deleteAudio: Bool) async throws {
        guard let url = meetingIndex[id] else {
            throw MeetingStoreError.meetingNotFound(id)
        }
        let mf = MeetingFolder(url: url)
        if !deleteAudio && FileManager.default.fileExists(atPath: mf.audioURL.path) {
            // Move audio out before deleting the folder so user keeps the recording.
            let salvageDir = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent) (audio kept)")
            try FileManager.default.createDirectory(at: salvageDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: mf.audioURL,
                to: salvageDir.appendingPathComponent(MeetingFolder.audioFilename)
            )
        }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        meetingIndex[id] = nil
        broadcast()
    }

    // MARK: - Folder CRUD

    public func createFolder(at parent: FolderNode, name: String) async throws -> FolderNode {
        let safe = sanitizedFolderName(name)
        guard !safe.isEmpty else { throw MeetingStoreError.invalidName(name) }
        let url = uniqueURL(parent: parent.url, base: safe)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        broadcast()
        return FolderNode(url: url, name: url.lastPathComponent, isMeeting: false, meeting: nil, children: [])
    }

    public func renameFolder(_ folder: FolderNode, to name: String) async throws {
        let safe = sanitizedFolderName(name)
        guard !safe.isEmpty else { throw MeetingStoreError.invalidName(name) }
        let parent = folder.url.deletingLastPathComponent()
        let dest = uniqueURL(parent: parent, base: safe)
        try FileManager.default.moveItem(at: folder.url, to: dest)
        broadcast()
    }

    public func deleteFolder(_ folder: FolderNode) async throws {
        try FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
        broadcast()
    }

    // MARK: - Segments + summary I/O

    public func appendSegments(_ segs: [TranscriptSegment], to id: UUID) async throws {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        let mf = MeetingFolder(url: url)
        var existing = try SegmentsFile.load(from: mf.segmentsURL)
        existing.append(contentsOf: segs.filter { !$0.isPartial })
        try SegmentsFile.save(existing, to: mf.segmentsURL)
        let meeting = try FolderTreeScanner.loadMeeting(from: mf.metadataURL)
        let summary = loadBodyIfExists(mf.summaryURL)
        let notes = loadBodyIfExists(mf.notesURL)
        let md = MarkdownTranscriptWriter.render(meeting: meeting, segments: existing, summary: summary, notes: notes)
        try AtomicWriter.write(Data(md.utf8), to: mf.transcriptURL)
    }

    public func replaceTranscript(_ segs: [TranscriptSegment], for id: UUID) async throws {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        let mf = MeetingFolder(url: url)
        let finals = segs.filter { !$0.isPartial }
        try SegmentsFile.save(finals, to: mf.segmentsURL)
        let meeting = try FolderTreeScanner.loadMeeting(from: mf.metadataURL)
        let summary = loadBodyIfExists(mf.summaryURL)
        let notes = loadBodyIfExists(mf.notesURL)
        let md = MarkdownTranscriptWriter.render(meeting: meeting, segments: finals, summary: summary, notes: notes)
        try AtomicWriter.write(Data(md.utf8), to: mf.transcriptURL)
    }

    public func importRawTranscript(_ text: String, for id: UUID) async throws {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        let mf = MeetingFolder(url: url)
        // Write the raw text directly to transcript.md.
        try AtomicWriter.write(Data(text.utf8), to: mf.transcriptURL)
        // Create a single segment so the summary generator can consume it.
        let segment = TranscriptSegment(
            speakerId: Speaker.others.id,
            channel: .mixed,
            start: 0,
            end: 0,
            text: text
        )
        try SegmentsFile.save([segment], to: mf.segmentsURL)
    }

    public func writeSummary(_ markdown: String, for id: UUID) async throws {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        let mf = MeetingFolder(url: url)
        try AtomicWriter.write(Data(markdown.utf8), to: mf.summaryURL)
    }

    public func loadTranscript(for id: UUID) async throws -> [TranscriptSegment] {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        return try SegmentsFile.load(from: MeetingFolder(url: url).segmentsURL)
    }

    public func loadSummary(for id: UUID) async throws -> String? {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        let summaryURL = MeetingFolder(url: url).summaryURL
        guard FileManager.default.fileExists(atPath: summaryURL.path) else { return nil }
        return try String(contentsOf: summaryURL, encoding: .utf8)
    }

    public func writeNotes(_ text: String, for id: UUID) async throws {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        let mf = MeetingFolder(url: url)
        try AtomicWriter.write(Data(text.utf8), to: mf.notesURL)
    }

    public func loadNotes(for id: UUID) async throws -> String? {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        let notesURL = MeetingFolder(url: url).notesURL
        guard FileManager.default.fileExists(atPath: notesURL.path) else { return nil }
        return try String(contentsOf: notesURL, encoding: .utf8)
    }

    // MARK: - helpers

    private func makeHandle(meeting: Meeting, folderURL: URL) -> MeetingHandle {
        let mf = MeetingFolder(url: folderURL)
        return MeetingHandle(
            meeting: meeting,
            folderURL: folderURL,
            transcriptURL: mf.transcriptURL,
            summaryURL: mf.summaryURL,
            segmentsURL: mf.segmentsURL,
            audioURL: meeting.hasAudio ? mf.audioURL : nil
        )
    }

    private func uniqueURL(parent: URL, base: String) -> URL {
        var url = parent.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(base) (\(n))")
            n += 1
        }
        return url
    }

    /// Produces a meeting folder name in `yyyy-MM-dd-name-title` format.
    /// Falls back to `yyyy-MM-dd-title` when no person name is available.
    private func meetingFolderName(for meeting: Meeting) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let datePart = df.string(from: meeting.startedAt)

        let person = meeting.person ?? meeting.attendees?.first(where: { $0.lowercased() != "you" })
        let namePart = person.map { slugify($0) }

        let titleSlug = slugify(meeting.title)

        var parts = [datePart]
        if let namePart, !namePart.isEmpty {
            parts.append(namePart)
            // Remove the person name from the title to avoid duplication.
            let cleanedTitle = titleSlug.replacingOccurrences(of: namePart, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .replacingOccurrences(of: "--", with: "-")
            if !cleanedTitle.isEmpty {
                parts.append(cleanedTitle)
            }
        } else if !titleSlug.isEmpty {
            parts.append(titleSlug)
        }
        return parts.joined(separator: "-")
    }

    /// Lowercases and replaces non-alphanumeric runs with hyphens.
    private func slugify(_ raw: String) -> String {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    /// Legacy: simple date+title format for drafts that haven't been enriched yet.
    private func sanitizedMeetingFolderName(date: Date, title: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let datePart = df.string(from: date)
        let safe = sanitizedFolderName(title)
        return safe.isEmpty ? datePart : "\(datePart) \(safe)"
    }

    private func sanitizedFolderName(_ raw: String) -> String {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // POSIX-illegal characters and leading dot.
        let bad = CharacterSet(charactersIn: "/:\u{0}\\")
        var out = stripped.unicodeScalars
            .filter { !bad.contains($0) }
            .reduce("") { $0 + String($1) }
        if out.hasPrefix(".") { out.removeFirst() }
        return out
    }

    /// Returns file content as a String if the file exists, nil otherwise.
    private func loadBodyIfExists(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Searches the folder tree for a non-meeting folder whose name matches
    /// `query` (case-insensitive). Used as a fallback when the person/org
    /// indexes have no entry yet — e.g. "Theresa" matches "10 One-to-Ones/Theresa/".
    private func findFolderByName(matching query: String, in node: FolderNode) -> URL? {
        let lower = query.lowercased()
        var stack: [FolderNode] = [node]
        while let n = stack.popLast() {
            guard !n.isMeeting else { continue }
            // Match folder name exactly (case-insensitive).
            if n.name.lowercased() == lower { return n.url }
            // Also match slug form: "Coysh Digital" matches "30-Coysh-Digital-Meetings".
            let slug = slugify(query)
            if !slug.isEmpty && n.name.lowercased().contains(slug) { return n.url }
            stack.append(contentsOf: n.children)
        }
        return nil
    }

    /// Updates the `folderRelativePath` in meeting.json after a move/rename.
    private func updateFolderRelativePath(for meeting: Meeting, at newURL: URL) throws {
        let newRelPath = newURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        var updated = meeting
        updated.folderRelativePath = newRelPath
        let mf = MeetingFolder(url: newURL)
        try FolderTreeScanner.writeMeeting(updated, to: mf.metadataURL)
    }
}
