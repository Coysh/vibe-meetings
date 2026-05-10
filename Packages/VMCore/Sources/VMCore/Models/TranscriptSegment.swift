import Foundation

public struct Word: Codable, Hashable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let probability: Float?

    public init(text: String, start: TimeInterval, end: TimeInterval, probability: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }
}

public struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var speakerId: String
    public var channel: AudioChannel
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var isPartial: Bool
    public var confidence: Float?
    public var words: [Word]?

    public init(
        id: UUID = UUID(),
        speakerId: String,
        channel: AudioChannel,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        isPartial: Bool = false,
        confidence: Float? = nil,
        words: [Word]? = nil
    ) {
        self.id = id
        self.speakerId = speakerId
        self.channel = channel
        self.start = start
        self.end = end
        self.text = text
        self.isPartial = isPartial
        self.confidence = confidence
        self.words = words
    }
}
