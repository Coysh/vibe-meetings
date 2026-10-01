import AppKit
import Observation
import SwiftUI

/// Owns the floating pill that shows "Not recording · Record" during a
/// detected call and a timer + Stop while recording.
///
/// It's a non-activating panel: it floats above other apps (including
/// full-screen Zoom/Teams) on every Space, never steals focus from the call,
/// and remembers where the user dragged it.
@MainActor
final class RecordingOverlayController {
    private static let autosaveName = "VibeMeetings.RecordingOverlay"

    private unowned let env: AppEnvironment
    private var panel: OverlayPanel?
    private var hostingView: FirstMouseHostingView<AnyView>?

    init(env: AppEnvironment) {
        self.env = env
    }

    func start() {
        observe()
    }

    /// Forget the dragged position; the pill returns to top-centre.
    static func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
    }

    // MARK: - Visibility

    private enum Mode: Equatable { case hidden, visible(String) }

    /// Re-evaluates whenever any observed state changes.
    private func observe() {
        let mode = withObservationTracking {
            currentMode()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(mode)
    }

    /// Reads exactly the state that decides visibility/size. The string
    /// changes whenever the pill's content changes shape, so it's resized.
    private func currentMode() -> Mode {
        guard env.showRecordingOverlay else { return .hidden }
        let service = env.recordingService
        if let controller = service.controller {
            return .visible("rec:\(controller.state):\(controller.meetingHandle?.meeting.title ?? "")")
        }
        if service.isStarting { return .visible("starting") }
        if let error = service.lastStartError { return .visible("error:\(error)") }
        if let call = env.bannerCoordinator.unrecordedCall {
            return .visible("call:\(call.id):\(env.bannerCoordinator.isCallSnoozed):\(env.bannerCoordinator.matchedEvent?.title ?? "")")
        }
        return .hidden
    }

    private func apply(_ mode: Mode) {
        switch mode {
        case .hidden:
            panel?.orderOut(nil)
        case .visible:
            let panel = ensurePanel()
            if !panel.isVisible {
                placeIfNeeded(panel)
                panel.orderFrontRegardless()
            }
            // Let SwiftUI render the new content before measuring it.
            Task { @MainActor [weak self] in self?.resizeToFit() }
        }
    }

    // MARK: - Panel

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }

        let root = AnyView(RecordingOverlayView().environment(env))
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []

        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // Above full-screen meeting windows; below menus and alerts.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI capsule draws its own
        panel.isMovableByWindowBackground = true
        // Best effort: keep the pill out of screen shares and recordings.
        panel.sharingType = .none
        panel.contentView = hosting
        panel.setFrameAutosaveName(Self.autosaveName)

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    /// First show (no saved position) or a saved position that's no longer
    /// on any screen (monitor unplugged): place it top-centre.
    private func placeIfNeeded(_ panel: NSPanel) {
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        let hasSaved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.autosaveName)") != nil
        guard !hasSaved || !onScreen else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = hostingView?.fittingSize ?? panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8))
    }

    /// Resize to the SwiftUI content, keeping the pill's top-centre fixed so
    /// it doesn't walk across the screen as its content changes.
    private func resizeToFit() {
        guard let panel, let hostingView, panel.isVisible else { return }
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        let old = panel.frame
        let frame = NSRect(
            x: (old.midX - size.width / 2).rounded(),
            y: old.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }
}

/// A panel that never becomes key or main, so clicking it doesn't pull focus
/// away from the meeting app.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons in the (never-key) overlay respond to the first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
