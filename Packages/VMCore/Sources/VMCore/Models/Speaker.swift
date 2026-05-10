import Foundation

public struct Speaker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var channel: AudioChannel?

    public init(id: String, displayName: String, channel: AudioChannel? = nil) {
        self.id = id
        self.displayName = displayName
        self.channel = channel
    }

    public static let you = Speaker(id: "you", displayName: "You", channel: .mic)
    public static let others = Speaker(id: "others", displayName: "Others", channel: .system)
    public static let imported = Speaker(id: "imported", displayName: "Imported", channel: .mixed)
}
