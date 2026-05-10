import Foundation

public enum AudioChannel: String, Codable, Hashable, Sendable, CaseIterable {
    case mic
    case system
    case mixed
}
