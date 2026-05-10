import Foundation

public enum AudioRetention: String, Codable, Sendable, CaseIterable {
    case keep
    case deleteAfterSummary
}

public enum SourceKind: Codable, Hashable, Sendable {
    case liveRecording
    case imported(originalFilename: String)
}

public struct EngineRef: Codable, Hashable, Sendable {
    public let kind: String
    public let version: String

    public init(kind: String, version: String) {
        self.kind = kind
        self.version = version
    }
}

public struct Meeting: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var folderRelativePath: String
    public var hasAudio: Bool
    public var audioRetention: AudioRetention
    public var transcriptionEngine: EngineRef
    public var summarizationEngine: EngineRef?
    public var modelId: String
    public var language: String?
    public var participants: [Speaker]
    public var tags: [String]
    public var sourceKind: SourceKind
    public var schemaVersion: Int

    public static let currentSchemaVersion = 1

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        folderRelativePath: String,
        hasAudio: Bool = false,
        audioRetention: AudioRetention = .keep,
        transcriptionEngine: EngineRef,
        summarizationEngine: EngineRef? = nil,
        modelId: String,
        language: String? = nil,
        participants: [Speaker] = [.you, .others],
        tags: [String] = [],
        sourceKind: SourceKind = .liveRecording,
        schemaVersion: Int = Meeting.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.folderRelativePath = folderRelativePath
        self.hasAudio = hasAudio
        self.audioRetention = audioRetention
        self.transcriptionEngine = transcriptionEngine
        self.summarizationEngine = summarizationEngine
        self.modelId = modelId
        self.language = language
        self.participants = participants
        self.tags = tags
        self.sourceKind = sourceKind
        self.schemaVersion = schemaVersion
    }

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}
