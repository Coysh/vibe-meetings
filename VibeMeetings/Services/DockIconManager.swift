import AppKit

/// Manages the dock icon badge to show a recording indicator overlay.
@MainActor
enum DockIconManager {
    private static var originalIcon: NSImage?

    /// Shows a red recording dot badge on the dock icon.
    static func showRecordingBadge() {
        guard let appIcon = NSApp.applicationIconImage else { return }

        // Cache the original icon on first call.
        if originalIcon == nil {
            originalIcon = appIcon.copy() as? NSImage
        }

        let size = appIcon.size
        let badged = NSImage(size: size)
        badged.lockFocus()

        // Draw the original icon.
        appIcon.draw(in: NSRect(origin: .zero, size: size))

        // Draw a red recording circle in the bottom-right corner.
        let badgeSize: CGFloat = size.width * 0.28
        let padding: CGFloat = size.width * 0.04
        let badgeRect = NSRect(
            x: size.width - badgeSize - padding,
            y: padding,
            width: badgeSize,
            height: badgeSize
        )

        // White ring background for contrast.
        let ringPath = NSBezierPath(ovalIn: badgeRect.insetBy(dx: -2, dy: -2))
        NSColor.white.withAlphaComponent(0.9).setFill()
        ringPath.fill()

        // Red recording dot.
        let dotPath = NSBezierPath(ovalIn: badgeRect)
        NSColor.systemRed.setFill()
        dotPath.fill()

        badged.unlockFocus()

        NSApp.applicationIconImage = badged
    }

    /// Removes the recording badge and restores the original dock icon.
    static func clearRecordingBadge() {
        if let original = originalIcon {
            NSApp.applicationIconImage = original
            originalIcon = nil
        } else {
            // Reset to default by setting nil — AppKit restores the bundle icon.
            NSApp.applicationIconImage = nil
        }
    }
}
