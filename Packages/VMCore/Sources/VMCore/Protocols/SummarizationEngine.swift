import Foundation

public protocol SummarizationEngine: Sendable {
    static var kind: String { get }
    var displayName: String { get }

    func isAvailable() async -> EngineHealth
    func availableModels() async throws -> [SummarizationModelInfo]

    /// Streams Markdown chunks. Caller appends to `summary.md` as they arrive.
    /// The stream finishes when the model emits its end-of-response token.
    /// `customPrompt` overrides the bundled system prompt when non-empty.
    func summarize(
        transcript: [TranscriptSegment],
        meeting: Meeting,
        modelId: String,
        style: SummaryStyle,
        userNotes: String?,
        customPrompt: String?
    ) -> AsyncThrowingStream<String, Error>
}

public enum SummarizationEngineError: Error, Sendable, Equatable, LocalizedError {
    case engineNotRunning
    case modelMissing(String)
    case requestFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .engineNotRunning: return "Summarization engine is not running"
        case .modelMissing(let name): return "Model not found: \(name)"
        case .requestFailed(let msg): return "Request failed: \(msg)"
        case .cancelled: return "Summarization was cancelled"
        }
    }
}
