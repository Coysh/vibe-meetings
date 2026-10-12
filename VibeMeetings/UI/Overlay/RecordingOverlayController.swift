import AppKit
import Observation
import SwiftUI

/// Owns the floating indicator: "Not recording · Record" during a detected
/// call, and a timer + Stop (or, Expanded, a live transcript card) while
/// recording.
///
/// It's a non-activating panel: it floats above other apps (including
/// full-screen Zoom/Teams) on every Space, never steals focus from the call,
/// can be dragged from anywhere, snaps to screen edges, and remembers where
/// it was left — one position for the pill (Compact/Standard), another for
/// the Expanded card, which is also resizable.
@MainActor
final class RecordingOverlayController: NSObject, NSWindowDelegate {
    private static let pillFrameKey = "VibeMeetings.Overlay.PillFrame"
    private static let expandedFrameKey = "VibeMeetings.Overlay.ExpandedFrame"
    /// Written by the NSWindow autosave this controller used before size modes.
    private static let legacyFrameKey = "NSWindow Frame VibeMeetings.RecordingOverlay"

    private static let snapDistance: CGFloat = 24
    private static let snapMargin: CGFloat = 8
    private static let pillFallbackSize = NSSize(width: 300, height: 44)
    private static let expandedMinSize = NSSize(width: 300, height: 220)
    private static let expandedMaxSize = NSSize(width: 640, height: 900)
    private static let expandedDefaultSize = NSSize(width: 360, height: 420)

    private unowned let env: AppEnvironment
    private var panel: OverlayPanel?
    private var hostingView: FirstMouseHostingView<AnyView>?
    private var appliedLayout: OverlayLayout?

    /// Set while this controller (not the user) moves the window, so those
    /// moves aren't treated as drags to snap and save.
    private var isProgrammaticMove = false
    private var snapTask: Task<Void, Never>?
    private var resizeGrab: (frame: NSRect, offset: NSPoint)?
    private var screenObserver: NSObjectProtocol?

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    func start() {
        migrateLegacyFrame()
        observe()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.keepOnScreen() }
        }
    }

    /// Forget the dragged positions; the indicator returns to top-centre now.
    func resetPosition() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pillFrameKey)
        defaults.removeObject(forKey: Self.expandedFrameKey)
        guard let panel, panel.isVisible, let visible = visibleFrame(for: panel.frame) else { return }
        let size = appliedLayout == .expanded ? Self.expandedDefaultSize : panel.frame.size
        setFrame(Self.topCentre(size: size, in: visible), animated: true)
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
        let layout = env.overlayLayout
        let service = env.recordingService
        if let controller = service.controller {
            return .visible("rec:\(controller.state):\(controller.meetingHandle?.meeting.title ?? ""):\(layout)")
        }
        if service.isStarting { return .visible("starting") }
        if let error = service.lastStartError { return .visible("error:\(error)") }
        if let call = env.bannerCoordinator.unrecordedCall {
            return .visible("call:\(call.id):\(env.bannerCoordinator.isCallSnoozed):\(env.bannerCoordinator.matchedEvent?.title ?? ""):\(layout)")
        }
        return .hidden
    }

    private func apply(_ mode: Mode) {
        switch mode {
        case .hidden:
            panel?.orderOut(nil)
        case .visible:
            let panel = ensurePanel()
            let layout = env.overlayLayout
            let wasVisible = panel.isVisible
            if !wasVisible || layout != appliedLayout {
                configure(panel, for: layout, wasVisible: wasVisible)
            }
            if !wasVisible { panel.orderFrontRegardless() }
            scheduleResize()
        }
    }

    // MARK: - Panel

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }

        let actions = OverlayActions(
            resize: { [weak self] began in self?.resizeFromGrip(began: began) },
            endResize: { [weak self] in self?.endResizeFromGrip() }
        )
        let root = AnyView(RecordingOverlayView(actions: actions).environment(env))
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []

        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillFallbackSize),
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
        // The window edges are the visible edges (the SwiftUI content is clipped to
        // its pill/card shape), so the system shadow follows the shape — and snapping
        // and resizing see the real edge instead of a transparent margin.
        panel.hasShadow = true
        // Dragging is `WindowDragGesture` in the view; the window-background route
        // doesn't see through NSHostingView and would only fight it.
        panel.isMovableByWindowBackground = false
        // Best effort: keep the indicator out of screen shares and recordings.
        panel.sharingType = .none
        panel.delegate = self
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    /// Switch the window between the pill and the Expanded card: resizability and
    /// frame, restoring each one's own remembered position.
    private func configure(_ panel: OverlayPanel, for layout: OverlayLayout, wasVisible: Bool) {
        let current = wasVisible ? panel.frame : nil
        appliedLayout = layout

        let frame: NSRect
        if layout == .expanded {
            panel.styleMask.insert(.resizable)
            panel.minSize = Self.expandedMinSize
            panel.maxSize = Self.expandedMaxSize
            frame = expandedFrame(anchoredTo: current)
        } else {
            panel.styleMask.remove(.resizable)
            panel.minSize = .zero
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            frame = pillFrame(current: current)
        }
        setFrame(frame, animated: false)
        panel.invalidateShadow()
    }

    private func pillFrame(current: NSRect?) -> NSRect {
        if let saved = savedFrame(expanded: false) { return saved }
        let size = current?.size ?? Self.pillFallbackSize
        let visible = (current.flatMap(visibleFrame(for:))) ?? (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return Self.topCentre(size: size, in: visible)
    }

    private func expandedFrame(anchoredTo current: NSRect?) -> NSRect {
        if let saved = savedFrame(expanded: true) { return saved }
        // No saved card yet: grow from wherever the pill is, keeping the edge it's snapped to.
        let anchor = current ?? savedFrame(expanded: false) ?? pillFrame(current: nil)
        let visible = visibleFrame(for: anchor) ?? .zero
        return Self.frame(size: Self.expandedDefaultSize, anchoredTo: anchor, in: visible)
    }

    // MARK: - Sizing

    /// Let SwiftUI render the new content, then fit the window to it (pill
    /// layouts only — Expanded is whatever size the user dragged it to). A second
    /// pass catches a layout switch whose content hadn't updated on the first.
    private func scheduleResize() {
        Task { @MainActor [weak self] in
            self?.resizeToFit()
            try? await Task.sleep(for: .milliseconds(80))
            self?.resizeToFit()
        }
    }

    /// Resize to the SwiftUI content, keeping the pill's anchored edge fixed so it
    /// doesn't walk across the screen as its content changes.
    private func resizeToFit() {
        guard let panel, let hostingView, panel.isVisible, appliedLayout != .expanded else { return }
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        guard let visible = visibleFrame(for: panel.frame) else { return }
        setFrame(Self.frame(size: size, anchoredTo: panel.frame, in: visible), animated: false)
        panel.invalidateShadow()
        saveFrame(panel.frame, expanded: false)
    }

    // MARK: - Dragging, snapping, resizing

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, snapTask == nil else { return }
        // A window-server drag swallows the mouse-up, and the app is usually inactive
        // so an event monitor wouldn't see it either — wait for the button instead.
        snapTask = Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard let self else { return }
            self.snapTask = nil
            await self.snapToEdges()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, appliedLayout == .expanded else { return }
        saveFrame(panel.frame, expanded: true)
    }

    /// After a drag: stick to a screen edge or corner if it's within reach (or past
    /// it), and keep the whole window on screen.
    private func snapToEdges() async {
        guard let panel, panel.isVisible, let visible = visibleFrame(for: panel.frame) else { return }
        var frame = panel.frame
        let margin = Self.snapMargin, reach = Self.snapDistance

        let left = frame.minX - (visible.minX + margin)
        let right = (visible.maxX - margin) - frame.maxX
        if left <= reach && (right > reach || left <= right) {
            frame.origin.x = visible.minX + margin
        } else if right <= reach {
            frame.origin.x = visible.maxX - margin - frame.width
        }

        let bottom = frame.minY - (visible.minY + margin)
        let top = (visible.maxY - margin) - frame.maxY
        if bottom <= reach && (top > reach || bottom <= top) {
            frame.origin.y = visible.minY + margin
        } else if top <= reach {
            frame.origin.y = visible.maxY - margin - frame.height
        }

        frame = Self.clamp(frame, in: visible)
        if frame != panel.frame {
            await moveAnimated(to: frame)
        }
        saveFrame(panel.frame, expanded: appliedLayout == .expanded)
    }

    private func moveAnimated(to frame: NSRect) async {
        guard let panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setFrame(frame, animated: false)
            return
        }
        isProgrammaticMove = true
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(frame, display: true)
        }
        isProgrammaticMove = false
        panel.invalidateShadow()
    }

    /// Resize handle (Expanded): the corner follows the mouse. Uses the screen
    /// mouse position, since the view moves with the window it's dragging.
    private func resizeFromGrip(began: Bool) {
        guard let panel, appliedLayout == .expanded else { return }
        let mouse = NSEvent.mouseLocation
        if began || resizeGrab == nil {
            let frame = panel.frame
            resizeGrab = (frame, NSPoint(x: frame.maxX - mouse.x, y: mouse.y - frame.minY))
        }
        guard let grab = resizeGrab else { return }

        let visible = visibleFrame(for: grab.frame) ?? .zero
        let maxWidth = min(panel.maxSize.width, visible.width), maxHeight = min(panel.maxSize.height, visible.height)
        let width = min(max(mouse.x + grab.offset.x - grab.frame.minX, panel.minSize.width), maxWidth)
        let height = min(max(grab.frame.maxY - (mouse.y - grab.offset.y), panel.minSize.height), maxHeight)
        setFrame(NSRect(x: grab.frame.minX, y: grab.frame.maxY - height, width: width, height: height), animated: false)
        panel.invalidateShadow()
    }

    private func endResizeFromGrip() {
        resizeGrab = nil
        guard let panel else { return }
        saveFrame(panel.frame, expanded: true)
        Task { await snapToEdges() }
    }

    /// A screen was added, removed or rearranged: pull the window back into view.
    private func keepOnScreen() {
        guard let panel, panel.isVisible, let visible = visibleFrame(for: panel.frame) else { return }
        let frame = Self.clamp(panel.frame, in: visible)
        if frame != panel.frame { setFrame(frame, animated: false) }
    }

    // MARK: - Frames

    private func setFrame(_ frame: NSRect, animated: Bool) {
        guard let panel else { return }
        isProgrammaticMove = true
        panel.setFrame(frame, display: true, animate: animated)
        isProgrammaticMove = false
    }

    /// The visible area of the screen holding most of `frame` (the main screen if none does).
    private func visibleFrame(for frame: NSRect) -> NSRect? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = screen.visibleFrame.intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        let best = NSScreen.screens.max { overlap($0) < overlap($1) }
        return (best ?? NSScreen.main)?.visibleFrame
    }

    private static func topCentre(size: NSSize, in visible: NSRect) -> NSRect {
        NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - snapMargin, width: size.width, height: size.height)
    }

    /// A frame of `size` that keeps the edges `old` is snapped to (left / right /
    /// centred horizontally, top / bottom vertically) in place.
    private static func frame(size: NSSize, anchoredTo old: NSRect, in visible: NSRect) -> NSRect {
        let tolerance = snapMargin + 2
        let x: CGFloat
        if abs(old.minX - visible.minX) <= tolerance {
            x = old.minX
        } else if abs(visible.maxX - old.maxX) <= tolerance {
            x = old.maxX - size.width
        } else {
            x = old.midX - size.width / 2
        }
        let y = abs(old.minY - visible.minY) <= tolerance ? old.minY : old.maxY - size.height
        return clamp(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), in: visible)
    }

    private static func clamp(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(result.width, visible.width)
        result.size.height = min(result.height, visible.height)
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    // MARK: - Persistence

    private func saveFrame(_ frame: NSRect, expanded: Bool) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: expanded ? Self.expandedFrameKey : Self.pillFrameKey)
    }

    /// The remembered frame, unless it's no longer on any screen (monitor unplugged).
    private func savedFrame(expanded: Bool) -> NSRect? {
        guard let string = UserDefaults.standard.string(forKey: expanded ? Self.expandedFrameKey : Self.pillFrameKey) else { return nil }
        let frame = NSRectFromString(string)
        guard frame.width > 0, frame.height > 0,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }

    /// The old autosave stored the window including its 10pt transparent shadow
    /// margin; carry the position over once, trimmed to the visible pill.
    private func migrateLegacyFrame() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: Self.legacyFrameKey) else { return }
        defaults.removeObject(forKey: Self.legacyFrameKey)
        guard defaults.string(forKey: Self.pillFrameKey) == nil else { return }
        let numbers = legacy.split(separator: " ").prefix(4).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 20, numbers[3] > 20 else { return }
        let frame = NSRect(x: numbers[0] + 10, y: numbers[1] + 10, width: numbers[2] - 20, height: numbers[3] - 20)
        defaults.set(NSStringFromRect(frame), forKey: Self.pillFrameKey)
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
