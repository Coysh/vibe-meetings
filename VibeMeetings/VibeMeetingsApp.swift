import SwiftUI

@main
struct VibeMeetingsApp: App {
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

extension Notification.Name {
    static let newMeetingRequested = Notification.Name("VibeMeetings.NewMeetingRequested")
}
