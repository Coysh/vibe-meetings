import Foundation
import Observation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so the rest
/// of the app doesn't import Sparkle directly.
@Observable
@MainActor
final class SparkleUpdater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// Whether a check can start now. Sparkle turns this off while it starts up and while a check is
    /// running, then back on, so it has to be followed rather than read once: the "Check for Updates…"
    /// menu item and the Settings button were stuck greyed out after launch when they only read it once.
    private(set) var canCheckForUpdates = false

    init() {
        // `startingUpdater: true` makes Sparkle check for updates on launch
        // according to its own schedule (respects SUEnableAutomaticChecks).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
