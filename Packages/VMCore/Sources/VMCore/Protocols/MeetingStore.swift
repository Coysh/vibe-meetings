import Foundation

public final class FolderNode: Identifiable, Hashable, @unchecked Sendable {
    public let id: String          // absolute path, stable per location
    public let url: URL
    public let name: String
    public let isMeeting: Bool     // true if folder contains meeting.json
    public let meeting: Meeting?   // populated when isMeeting
    public let children: [FolderNode]

    public init(
        url: URL,
        name: String,
        isMeeting: Bool,
        meeting: Meeting?,
        children: [FolderNode]
    ) {
        self.id = url.path
        self.url = url
        self.name = name
        self.isMeeting = isMeeting
        self.meeting = meeting
        self.children = children
    }

    public static func == (lhs: FolderNode, rhs: FolderNode) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct MeetingHandle: Sendable {
    public let meeting: Meeting
    public let folderURL: URL
    public let transcriptURL: URL
    public let summaryURL: URL
    public let segmentsURL: URL
    public let audioURL: URL?

    public init(
        meeting: Meeting,
        folderURL: URL,
        transcriptURL: URL,
        summaryURL: URL,
        segmentsURL: URL,
        audioURL: URL?
    ) {
        self.meeting = meeting
        self.folderURL = folderURL
        self.transcriptURL = transcriptURL
        self.summaryURL = summaryURL
        self.segmentsURL = segmentsURL
        self.audioURL = audioURL
    }
}

public struct MeetingDraft: Sendable {
    public var title: String
    public var startedAt: Date
    public var transcriptionEngine: EngineRef
    public var summarizationEngine: EngineRef?
    public var modelId: String
    public var language: String?
    public var sourceKind: SourceKind

    public init(
        title: String,
        startedAt: Date = Date(),
        transcriptionEngine: EngineRef,
        summarizationEngine: EngineRef? = nil,
        modelId: String,
        language: String? = nil,
        sourceKind: SourceKind = .liveRecording
    ) {
        self.title = title
        self.startedAt = startedAt
        self.transcriptionEngine = transcriptionEngine
        self.summarizationEngine = summarizationEngine
        self.modelId = modelId
        self.language = language
        self.sourceKind = sourceKind
    }
}

public protocol MeetingStore: Sendable {
    /// The root folder URL the store is rooted at. Read-only.
    var rootURL: URL { get }

    /// Live tree, refreshed by FSEvents. The first element is emitted synchronously.
    var tree: AsyncStream<FolderNode> { get }

    func currentTree() async -> FolderNode

    func createMeeting(in folder: FolderNode, draft: MeetingDraft) async throws -> MeetingHandle
    func openMeeting(id: UUID) async throws -> MeetingHandle
    func renameMeeting(id: UUID, to title: String) async throws
    func moveMeeting(id: UUID, to folder: FolderNode) async throws
    func deleteMeeting(id: UUID, deleteAudio: Bool) async throws

    func createFolder(at parent: FolderNode, name: String) async throws -> FolderNode
    func renameFolder(_ folder: FolderNode, to name: String) async throws
    func deleteFolder(_ folder: FolderNode) async throws

    func appendSegments(_ segs: [TranscriptSegment], to id: UUID) async throws
    func replaceTranscript(_ segs: [TranscriptSegment], for id: UUID) async throws
    func writeSummary(_ markdown: String, for id: UUID) async throws
    func loadTranscript(for id: UUID) async throws -> [TranscriptSegment]
    func loadSummary(for id: UUID) async throws -> String?
}

public enum MeetingStoreError: Error, Sendable, Equatable {
    case meetingNotFound(UUID)
    case folderNotEmpty(URL)
    case nameConflict(String)
    case invalidName(String)
    case ioFailure(String)
}
