import Foundation

public struct TranscriptionOptions: Sendable {
    public var language: String?
    public var translate: Bool
    public var initialPrompt: String?
    public var temperature: Float
    public var beamSize: Int
    public var enableWordTimestamps: Bool
    public var noSpeechThreshold: Float
    /// Live streaming strategy: commit settled text and advance (true), or re-decode a sliding window and
    /// let each decode replace the last (false, the original behaviour — kept for comparison).
    public var commitStreaming: Bool
    /// How much new audio to wait for between live decodes. Measured on real recordings: 5 s keeps both
    /// sides of a call within real time on the medium model, where 3 s did not.
    public var liveHopSeconds: Double
    /// How much of the text just settled is handed back to the model as context (characters). Off by
    /// default: on real recordings it made decoding about 50% slower with no gain in accuracy, because every
    /// prompt token costs a decoder step and any prompt also turns off WhisperKit's fast prefill cache.
    public var liveContextCharacters: Int

    public init(
        language: String? = nil,
        translate: Bool = false,
        initialPrompt: String? = nil,
        temperature: Float = 0.0,
        beamSize: Int = 5,
        enableWordTimestamps: Bool = true,
        noSpeechThreshold: Float = 0.6,
        commitStreaming: Bool = true,
        liveHopSeconds: Double = 5,
        liveContextCharacters: Int = 0
    ) {
        self.language = language
        self.translate = translate
        self.initialPrompt = initialPrompt
        self.temperature = temperature
        self.beamSize = beamSize
        self.enableWordTimestamps = enableWordTimestamps
        self.noSpeechThreshold = noSpeechThreshold
        self.commitStreaming = commitStreaming
        self.liveHopSeconds = liveHopSeconds
        self.liveContextCharacters = liveContextCharacters
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
