import AppKit
import SwiftUI

/// Brings the main window forward — or recreates it if the user closed it —
/// from places that have no SwiftUI window of their own (notification
/// actions, the menu bar extra, the floating overlay).
@MainActor
final class MainWindowPresenter {
    static let windowID = "main"

    /// Registered by any live SwiftUI view (RootView, the menu bar label).
    /// SwiftUI's `openWindow` keeps working after the view's window closes.
    var openWindow: OpenWindowAction?

    /// The WindowGroup's open window. SwiftUI names it "main-AppWindow-N"; if
    /// that ever changes, fall back to any ordinary document-style window.
    /// Closed windows SwiftUI hasn't released yet are ignored — reopening
    /// goes through `openWindow` so the content is rebuilt.
    var mainWindow: NSWindow? {
        let candidates = NSApp.windows.filter {
            $0.canBecomeMain && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized)
        }
        return candidates.first { $0.identifier?.rawValue.hasPrefix(Self.windowID) == true }
            ?? candidates.first {
                let id = $0.identifier?.rawValue ?? ""
                return id != "about-vibe-meetings" && !id.localizedCaseInsensitiveContains("settings")
                    && $0.contentViewController != nil
            }
    }

    /// True when the main window is on screen (not closed or minimised).
    var isMainWindowVisible: Bool {
        guard let w = mainWindow else { return false }
        return w.isVisible && !w.isMiniaturized
    }

    /// True when the user is actually looking at the main window.
    var isMainWindowKey: Bool {
        NSApp.isActive && (mainWindow?.isKeyWindow ?? false)
    }

    func show() {
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: Self.windowID)
        } else {
            // No SwiftUI hook available: a reopen event makes SwiftUI create
            // a fresh window for the WindowGroup.
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }
}
