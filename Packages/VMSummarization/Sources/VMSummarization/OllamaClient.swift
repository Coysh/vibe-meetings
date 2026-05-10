import Foundation
import VMCore

/// Internal HTTP client for Ollama. The public surface of this package is
/// `OllamaEngine`; this client is an implementation detail and stays
/// internal so the request/response types in `OllamaTypes.swift` don't
/// need to be public.
final class OllamaClient: @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
        self.session = LocalhostOnlySession.loopbackOnly(timeout: 10)
    }

    func version() async -> EngineHealth {
        do {
            let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/version"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unreachable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let v = try JSONDecoder().decode(OllamaVersion.self, from: data)
            return .ok(version: v.version)
        } catch let e as URLError where e.code == .cannotConnectToHost {
            return .notRunning
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    func listModels() async throws -> [OllamaTagEntry] {
        let (data, _) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
        return try JSONDecoder().decode(OllamaTagsResponse.self, from: data).models
    }

    func show(name: String) async throws -> OllamaShowResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(OllamaShowRequest(name: name))
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(OllamaShowResponse.self, from: data)
    }

    /// Streams chat response chunks (one decoded `OllamaChatStreamChunk` per emitted line).
    func streamChat(_ request: OllamaChatRequest) -> AsyncThrowingStream<OllamaChatStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 600
                    req.httpBody = try JSONEncoder().encode(request)

                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw SummarizationEngineError.requestFailed("HTTP \(code)")
                    }
                    for try await line in bytes.lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(OllamaChatStreamChunk.self, from: data)
                        continuation.yield(chunk)
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
