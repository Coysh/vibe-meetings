import Foundation
import VMCore

public final class OllamaEngine: SummarizationEngine, @unchecked Sendable {
    public static let kind = "ollama"
    public let displayName = "Ollama (local)"

    private let client: OllamaClient
    private let promptBundle: Bundle?

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, promptBundle: Bundle? = nil) {
        self.client = OllamaClient(baseURL: baseURL)
        self.promptBundle = promptBundle
    }

    public func isAvailable() async -> EngineHealth {
        await client.version()
    }

    public func availableModels() async throws -> [SummarizationModelInfo] {
        let entries = try await client.listModels()
        return entries.map { e in
            SummarizationModelInfo(id: e.name, displayName: e.name, sizeBytes: e.size, contextLength: nil)
        }
    }

    public func summarize(
        transcript: [TranscriptSegment],
        meeting: Meeting,
        modelId: String,
        style: SummaryStyle,
        userNotes: String? = nil,
        customPrompt: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let speakerNames = Dictionary(uniqueKeysWithValues: meeting.participants.map { ($0.id, $0.displayName) })
                    let body = PromptLoader.renderTranscript(transcript, speakerNames: speakerNames, meeting: meeting, userNotes: userNotes)
                    let system = PromptLoader.systemPrompt(style: style, bundle: self.promptBundle, customPrompt: customPrompt)

                    let req = OllamaChatRequest(
                        model: modelId,
                        messages: [
                            .init(role: "system", content: system),
                            .init(role: "user", content: body)
                        ],
                        stream: true,
                        options: .init(temperature: 0.2, num_ctx: nil)
                    )

                    for try await chunk in self.client.streamChat(req) {
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
