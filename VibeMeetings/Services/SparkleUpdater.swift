import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so the rest
/// of the app doesn't import Sparkle directly.
@MainActor
final class SparkleUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` makes Sparkle check for updates on launch
        // according to its own schedule (respects SUEnableAutomaticChecks).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
