import Foundation

public protocol SummarizationEngine: Sendable {
    static var kind: String { get }
    var displayName: String { get }

    func isAvailable() async -> EngineHealth
    func availableModels() async throws -> [SummarizationModelInfo]

    /// Streams Markdown chunks. Caller appends to `summary.md` as they arrive.
    /// The stream finishes when the model emits its end-of-response token.
    func summarize(
        transcript: [TranscriptSegment],
        meeting: Meeting,
        modelId: String,
        style: SummaryStyle
    ) -> AsyncThrowingStream<String, Error>
}

public enum SummarizationEngineError: Error, Sendable, Equatable {
    case engineNotRunning
    case modelMissing(String)
    case requestFailed(String)
    case cancelled
}
