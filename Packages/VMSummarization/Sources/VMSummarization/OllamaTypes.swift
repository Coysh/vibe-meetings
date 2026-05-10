import Foundation

struct OllamaVersion: Decodable {
    let version: String
}

struct OllamaTagsResponse: Decodable {
    let models: [OllamaTagEntry]
}

struct OllamaTagEntry: Decodable {
    let name: String
    let size: Int64?
    let details: OllamaTagDetails?
}

struct OllamaTagDetails: Decodable {
    let parameter_size: String?
    let quantization_level: String?
}

struct OllamaShowRequest: Encodable {
    let name: String
}

struct OllamaShowResponse: Decodable {
    let model_info: [String: AnyCodable]?
    let parameters: String?
}

struct OllamaChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct Options: Encodable {
        let temperature: Double?
        let num_ctx: Int?
    }
    let model: String
    let messages: [Message]
    let stream: Bool
    let options: Options?
}

struct OllamaChatStreamChunk: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }
    let model: String
    let created_at: String?
    let message: Message?
    let done: Bool
    let done_reason: String?
}

/// Minimal `Codable` wrapper for opaque JSON values (used when reading
/// `model_info` from `/api/show`).
struct AnyCodable: Codable {
    let value: Any?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let arr = try? c.decode([AnyCodable].self) { value = arr.map(\.value) }
        else if let dict = try? c.decode([String: AnyCodable].self) { value = dict.mapValues(\.value) }
        else { value = nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case nil: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        default: try c.encodeNil()
        }
    }
}
