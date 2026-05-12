import Foundation
import VMCore

/// `SummarizationEngine` backed by the OpenAI Chat Completions API.
/// Uses a standard URLSession (not `LocalhostOnlySession`) since the
/// user has explicitly opted in by providing their API key.
public final class OpenAIEngine: SummarizationEngine, @unchecked Sendable {
    public static let kind = "openai"
    public let displayName = "OpenAI"

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let promptBundle: Bundle?

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        promptBundle: Bundle? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.promptBundle = promptBundle

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func isAvailable() async -> EngineHealth {
        guard !apiKey.isEmpty else { return .unreachable("No API key configured") }
        do {
            var req = URLRequest(url: baseURL.appendingPathComponent("models"))
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 10
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("Invalid response")
            }
            if http.statusCode == 200 {
                return .ok(version: "API")
            } else if http.statusCode == 401 {
                return .unreachable("Invalid API key")
            } else {
                return .unreachable("HTTP \(http.statusCode)")
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    public func availableModels() async throws -> [SummarizationModelInfo] {
        guard !apiKey.isEmpty else { return [] }
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, _) = try await session.data(for: req)
        let resp = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        // Filter to GPT chat models only
        let chatModels = resp.data.filter {
            $0.id.hasPrefix("gpt-") || $0.id.hasPrefix("o")
        }.sorted { $0.id < $1.id }
        return chatModels.map {
            SummarizationModelInfo(id: $0.id, displayName: $0.id)
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
                    let speakerNames = Dictionary(
                        uniqueKeysWithValues: meeting.participants.map { ($0.id, $0.displayName) }
                    )
                    let body = PromptLoader.renderTranscript(transcript, speakerNames: speakerNames, meeting: meeting, userNotes: userNotes)
                    let system = PromptLoader.systemPrompt(style: style, bundle: self.promptBundle, customPrompt: customPrompt)

                    let chatReq = OpenAIChatRequest(
                        model: modelId,
                        messages: [
                            .init(role: "system", content: system),
                            .init(role: "user", content: body)
                        ],
                        stream: true,
                        temperature: nil
                    )

                    let encodedBody = try JSONEncoder().encode(chatReq)

                    // Retry with exponential backoff for rate-limit (429) errors.
                    let maxRetries = 4
                    var attempt = 0
                    var lastCode = 0

                    while true {
                        var req = URLRequest(url: self.baseURL.appendingPathComponent("chat/completions"))
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                        req.timeoutInterval = 600
                        req.httpBody = encodedBody

                        print("[OpenAI] requesting chat/completions with model=\(modelId) (attempt \(attempt + 1))")
                        let (bytes, response) = try await self.session.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else {
                            throw SummarizationEngineError.requestFailed("Invalid response from OpenAI")
                        }
                        lastCode = http.statusCode

                        if (200..<300).contains(http.statusCode) {
                            // Success — stream the response.
                            for try await line in bytes.lines {
                                guard line.hasPrefix("data: ") else { continue }
                                let payload = String(line.dropFirst(6))
                                if payload == "[DONE]" { break }
                                guard let data = payload.data(using: .utf8) else { continue }
                                let chunk = try JSONDecoder().decode(OpenAIChatStreamChunk.self, from: data)
                                if let content = chunk.choices?.first?.delta.content, !content.isEmpty {
                                    continuation.yield(content)
                                }
                            }
                            break // Done — exit retry loop.
                        } else if http.statusCode == 429 && attempt < maxRetries {
                            // Rate limited — respect Retry-After or use exponential backoff.
                            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                                .flatMap(Double.init) ?? Double(1 << attempt)
                            let delay = min(retryAfter, 60.0)
                            print("[OpenAI] rate limited (429), retrying in \(delay)s (attempt \(attempt + 1)/\(maxRetries))")
                            try await Task.sleep(for: .seconds(delay))
                            attempt += 1
                            continue
                        } else {
                            // Read the error body for a more descriptive message.
                            var errorBody = ""
                            for try await line in bytes.lines {
                                errorBody += line
                                if errorBody.count > 500 { break }
                            }
                            print("[OpenAI] request failed with HTTP \(http.statusCode): \(errorBody)")
                            if http.statusCode == 400 {
                                throw SummarizationEngineError.requestFailed("OpenAI rejected the request (model=\(modelId)). Check the model name in Settings > Engines. Error: \(errorBody)")
                            }
                            throw SummarizationEngineError.requestFailed("OpenAI returned HTTP \(http.statusCode)")
                        }
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
