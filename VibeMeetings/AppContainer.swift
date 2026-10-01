import Foundation

/// Holds the single `AppEnvironment`, shared by the SwiftUI `App` (scenes)
/// and the `AppDelegate` (notification actions, launch-time bootstrap).
@MainActor
enum AppContainer {
    static let env: AppEnvironment? = {
        do { return try AppEnvironment() }
        catch {
            print("Failed to bootstrap AppEnvironment: \(error)")
            return nil
        }
    }()
}
