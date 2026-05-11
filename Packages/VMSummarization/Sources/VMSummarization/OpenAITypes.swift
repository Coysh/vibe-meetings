import Foundation

struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double?
}

struct OpenAIChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
        let finish_reason: String?
    }
    let choices: [Choice]?
}

struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let owned_by: String?
    }
    let data: [Model]
}
