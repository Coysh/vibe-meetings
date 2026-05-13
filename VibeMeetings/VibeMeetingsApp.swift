import SwiftUI
import UserNotifications

@main
struct VibeMeetingsApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    @State private var appEnv: AppEnvironment? = {
        do { return try AppEnvironment() }
        catch {
            print("Failed to bootstrap AppEnvironment: \(error)")
            return nil
        }
    }()

    var body: some Scene {
        WindowGroup("vibe-meetings") {
            Group {
                if let env = appEnv {
                    RootView()
                        .environment(env)
                        .onChange(of: env.activeRecordingController != nil) { _, isRecording in
                            if isRecording {
                                DockIconManager.showRecordingBadge()
                            } else {
                                DockIconManager.clearRecordingBadge()
                            }
                        }
                        .onAppear {
                            BannerCoordinator.registerNotificationCategory()
                            UNUserNotificationCenter.current().delegate = appDelegate
                        }
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
                    NotificationCenter.default.post(name: .newMeetingRequested, object: nil)
                }
                .keyboardShortcut("n")
            }
        }

        Settings {
            if let env = appEnv {
                SettingsView()
                    .environment(env)
            }
        }
    }
}

/// Handles notification actions (e.g., "Start Recording" from the meeting detection notification).
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Called when the user taps a notification action while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        if action == BannerCoordinator.startRecordingAction
            || action == BannerCoordinator.startListeningAction {
            // Bring app to front and trigger the new meeting flow.
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .newMeetingRequested, object: nil)
            }
        } else if action == BannerCoordinator.joinAndRecordAction {
            // Open the Teams URL, then start recording.
            if let urlString = userInfo["teamsURL"] as? String,
               let url = URL(string: urlString) {
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
                // Small delay to let Teams launch before showing the recording sheet.
                try? await Task.sleep(for: .milliseconds(1500))
            }
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .newMeetingRequested, object: nil)
            }
        } else if action == UNNotificationDefaultActionIdentifier {
            // User tapped the notification body itself — bring app to front.
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Show notifications even when app is in the foreground (so the banner and notification both work).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension Notification.Name {
    static let newMeetingRequested = Notification.Name("VibeMeetings.NewMeetingRequested")
}
