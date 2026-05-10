import Foundation

public enum EngineHealth: Sendable, Equatable {
    case ok(version: String)
    case notRunning
    case unreachable(String)
    case modelMissing(String)

    public var isOk: Bool {
        if case .ok = self { return true }
        return false
    }
}
