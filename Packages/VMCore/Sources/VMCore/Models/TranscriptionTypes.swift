import Foundation

public struct TranscriptionOptions: Sendable {
    public var language: String?
    public var translate: Bool
    public var initialPrompt: String?
    public var temperature: Float
    public var beamSize: Int
    public var enableWordTimestamps: Bool
    public var noSpeechThreshold: Float

    public init(
        language: String? = nil,
        translate: Bool = false,
        initialPrompt: String? = nil,
        temperature: Float = 0.0,
        beamSize: Int = 5,
        enableWordTimestamps: Bool = true,
        noSpeechThreshold: Float = 0.6
    ) {
        self.language = language
        self.translate = translate
        self.initialPrompt = initialPrompt
        self.temperature = temperature
        self.beamSize = beamSize
        self.enableWordTimestamps = enableWordTimestamps
        self.noSpeechThreshold = noSpeechThreshold
    }

    public static let `default` = TranscriptionOptions()
}

public struct TranscriptionModelInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let sizeBytes: Int64
    public let isDownloaded: Bool
    public let recommended: Bool

    public init(id: String, displayName: String, sizeBytes: Int64, isDownloaded: Bool, recommended: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.isDownloaded = isDownloaded
        self.recommended = recommended
    }
}

public enum SummaryStyle: String, Sendable, CaseIterable, Codable {
    case standard
    case brief
    case decisionsAndActions
    case verbatimNotes
}

public struct SummarizationModelInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let sizeBytes: Int64?
    public let contextLength: Int?

    public init(id: String, displayName: String, sizeBytes: Int64? = nil, contextLength: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.contextLength = contextLength
    }
}
