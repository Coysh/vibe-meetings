import Foundation
import VMCore

public actor FilesystemMeetingStore: MeetingStore {
    public nonisolated let rootURL: URL

    private var cachedTree: FolderNode
    private var meetingIndex: [UUID: URL] = [:]
    private var watcher: FolderWatcher?
    private var subscribers: [UUID: AsyncStream<FolderNode>.Continuation] = [:]

    public init(rootURL: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootURL.path) {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        self.rootURL = rootURL
        self.cachedTree = FolderTreeScanner.scan(root: rootURL)
        self.meetingIndex = FolderTreeScanner.indexMeetings(in: self.cachedTree)
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
        for (_, c) in subscribers { c.yield(cachedTree) }
    }

    private func broadcast() { refreshFromDisk() }

    // MARK: - Meeting CRUD

    public func createMeeting(in folder: FolderNode, draft: MeetingDraft) async throws -> MeetingHandle {
        let parent = folder.url
        let folderName = sanitizedMeetingFolderName(date: draft.startedAt, title: draft.title)
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
            sourceKind: draft.sourceKind
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
        let newName = sanitizedMeetingFolderName(date: meeting.startedAt, title: title)
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
        let md = MarkdownTranscriptWriter.render(meeting: meeting, segments: existing)
        try AtomicWriter.write(Data(md.utf8), to: mf.transcriptURL)
    }

    public func replaceTranscript(_ segs: [TranscriptSegment], for id: UUID) async throws {
        guard let url = meetingIndex[id] else { throw MeetingStoreError.meetingNotFound(id) }
        let mf = MeetingFolder(url: url)
        let finals = segs.filter { !$0.isPartial }
        try SegmentsFile.save(finals, to: mf.segmentsURL)
        let meeting = try FolderTreeScanner.loadMeeting(from: mf.metadataURL)
        let md = MarkdownTranscriptWriter.render(meeting: meeting, segments: finals)
        try AtomicWriter.write(Data(md.utf8), to: mf.transcriptURL)
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
}
