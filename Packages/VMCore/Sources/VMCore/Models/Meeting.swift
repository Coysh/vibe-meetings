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

public enum MeetingType: String, Codable, Sendable, CaseIterable {
    case oneOnOne = "1-1"
    case group = "meeting"

    /// Auto-detect from title string. Returns `.oneOnOne` if the title
    /// contains common 1:1 patterns, `.group` otherwise.
    public static func detect(from title: String) -> MeetingType {
        let lower = title.lowercased()
        let patterns = ["1:1", "1-1", "one to one", "one-to-one", "1 to 1", "1 on 1", "one on one"]
        return patterns.contains(where: { lower.contains($0) }) ? .oneOnOne : .group
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

    // Schema v2 (2026-05): calendar integration. All optional → v1 files
    // decode unchanged and are upgraded lazily on next write.
    public var calendarEventID: String?         // EKEvent.eventIdentifier — per-occurrence
    public var calendarSeriesID: String?        // calendarItemExternalIdentifier — stable per series
    public var meetingPlatform: MeetingPlatform?
    public var calendarTitle: String?           // event title at creation; preserved if user renames the meeting

    // Schema v3 (2026-05): meeting metadata enrichment. All optional → v2 files
    // decode unchanged and are upgraded lazily on next write.
    public var meetingType: MeetingType?
    public var labels: [String]?
    public var attendees: [String]?
    public var org: String?

    public static let currentSchemaVersion = 3

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
        schemaVersion: Int = Meeting.currentSchemaVersion,
        calendarEventID: String? = nil,
        calendarSeriesID: String? = nil,
        meetingPlatform: MeetingPlatform? = nil,
        calendarTitle: String? = nil,
        meetingType: MeetingType? = nil,
        labels: [String]? = nil,
        attendees: [String]? = nil,
        org: String? = nil
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
        self.calendarEventID = calendarEventID
        self.calendarSeriesID = calendarSeriesID
        self.meetingPlatform = meetingPlatform
        self.calendarTitle = calendarTitle
        self.meetingType = meetingType
        self.labels = labels
        self.attendees = attendees
        self.org = org
    }

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// The resolved meeting type, falling back to auto-detection from title.
    public var resolvedType: MeetingType {
        meetingType ?? MeetingType.detect(from: title)
    }

    /// For 1:1 meetings, the other person's name (first attendee that isn't "You").
    /// Returns nil for group meetings or when no attendees are set.
    public var person: String? {
        guard resolvedType == .oneOnOne else { return nil }
        return attendees?.first(where: { $0.lowercased() != "you" }) ?? attendees?.first
    }

    /// Tags auto-computed from labels + system tags. Used for transcript.md front-matter.
    public var computedTags: [String] {
        var result = labels ?? []
        result.append("meeting")
        result.append("transcript")
        result.append(resolvedType.rawValue)
        // Deduplicate while preserving order.
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
