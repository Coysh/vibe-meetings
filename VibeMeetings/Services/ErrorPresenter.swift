import Foundation

/// A failure of something the user asked for, shown in an alert on the main window.
///
/// Most user-initiated writes (save notes, rename, move, import, delete…) used
/// to be `try?` — if the disk was full, the folder was read-only or a file was
/// locked, the user saw nothing and assumed it had worked.
struct PresentedError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

extension AppEnvironment {
    /// Show "Couldn't <action>" with the underlying reason.
    func presentError(_ error: Error, while action: String) {
        presentedError = PresentedError(
            title: "Couldn't \(action)",
            message: error.localizedDescription
        )
    }

    /// Run `body`; on failure, present the error and return `nil`.
    @discardableResult
    func attempt<T>(_ action: String, _ body: () async throws -> T) async -> T? {
        do {
            return try await body()
        } catch {
            presentError(error, while: action)
            return nil
        }
    }
}
