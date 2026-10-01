import SwiftUI
import UserNotifications

@main
struct VibeMeetingsApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    @State private var appEnv: AppEnvironment? = AppContainer.env
    @AppStorage(AppEnvironment.menuBarEnabledKey) private var showMenuBar = true

    var body: some Scene {
        WindowGroup("vibe-meetings", id: MainWindowPresenter.windowID) {
            Group {
                if let env = appEnv {
                    RootView()
                        .environment(env)
                } else {
                    Text("Failed to start. See log.")
                        .frame(minWidth: 600, minHeight: 400)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Meeting…") {
                    appEnv?.appRouter.requestNewMeeting()
                    appEnv?.presenter.show()
                }
                .keyboardShortcut("n")
            }
            CommandGroup(replacing: .appInfo) {
                Button("About vibe-meetings") {
                    showAboutWindow()
                }
                Divider()
                Button("Check for Updates…") {
                    appEnv?.sparkleUpdater.checkForUpdates()
                }
                .disabled(appEnv?.sparkleUpdater.canCheckForUpdates != true)
            }
        }

        Settings {
            if let env = appEnv {
                SettingsView()
                    .environment(env)
            }
        }

        // Read-only binding: SwiftUI writes the status item's visibility back
        // through `isInserted` whenever AppKit/the system touches it. Feeding
        // that into @AppStorage re-invalidates the scene graph, which updates
        // the status item again — an endless main-thread loop (1.7.0 froze on
        // launch). The Settings toggle is the only writer.
        MenuBarExtra(isInserted: Binding(get: { showMenuBar }, set: { _ in })) {
            if let env = appEnv {
                MenuBarContentView()
                    .environment(env)
            }
        } label: {
            if let env = appEnv {
                MenuBarLabel()
                    .environment(env)
            } else {
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Installs the notification delegate before launch finishes (so a
/// notification click that launches the app isn't dropped) and starts the
/// app-wide services independently of any window.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerCategories()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let env = AppContainer.env else { return }
        env.bootstrap()
        NotificationActionRouter.shared.attach(env)
    }

    /// Keep running (call detection, reminders, menu bar) with no windows open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no windows reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /// Notification button or body clicked.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Copy what we need before hopping actors — the response isn't Sendable.
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        var userInfo: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String { userInfo[key] = value }
        }
        await MainActor.run {
            NotificationActionRouter.shared.handle(action: action, category: category, userInfo: userInfo)
        }
    }

    /// Show notifications while the app is in the foreground too — except
    /// "please record" nags once a recording is already running.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        let recording = await MainActor.run { AppContainer.env?.recordingService.isBusy ?? false }
        if recording && NotificationManager.Category.recordingNags.contains(category) {
            return []
        }
        return [.banner, .list, .sound]
    }
}

/// Opens a standalone About window (replacing the default macOS About panel).
@MainActor
private func showAboutWindow() {
    let windowID = "about-vibe-meetings"
    // Re-focus if already open.
    if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == windowID }) {
        existing.makeKeyAndOrderFront(nil)
        return
    }
    let hosting = NSHostingController(rootView: AboutView())
    let window = NSWindow(contentViewController: hosting)
    window.identifier = NSUserInterfaceItemIdentifier(windowID)
    window.title = "About vibe-meetings"
    window.styleMask = [.titled, .closable]
    window.center()
    window.makeKeyAndOrderFront(nil)
}
