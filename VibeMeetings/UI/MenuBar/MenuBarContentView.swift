import AppKit
import SwiftUI
import VMCore

/// Menu shown from the menu bar icon: recording state plus one-click
/// Record / Stop, usable with the main window closed.
struct MenuBarContentView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        let service = env.recordingService
        let banner = env.bannerCoordinator

        Text(statusLine).font(.headline)

        if let controller = service.controller {
            if controller.state == .recording || controller.state == .paused {
                Button("Stop Recording") {
                    Task { await service.stop() }
                }
            }
            Button("Show Live Transcript") {
                if let id = controller.meetingHandle?.meeting.id {
                    env.appRouter.selectMeetingID = id
                }
                env.presenter.show()
            }
        } else if !service.isStarting {
            Button(recordTitle) {
                Task { await service.startDetectedCall() }
            }
            if let event = banner.joinableEvent, banner.currentCall == nil {
                Button("Join & Record “\(event.title)”") {
                    Task { await service.joinAndRecord(event: event) }
                }
            }
            if let call = banner.unrecordedCall {
                if !banner.isCallSnoozed {
                    Button("Snooze Reminders for 10 Minutes") { banner.snooze(sessionID: call.id) }
                }
                Button("Not a Meeting") { banner.notAMeeting(sessionID: call.id) }
            }
        }

        Divider()

        Button("New Meeting…") {
            env.appRouter.requestNewMeeting()
            env.presenter.show()
        }
        Button("Open vibe-meetings") { env.presenter.show() }
        Toggle("Show Floating Indicator", isOn: $env.showRecordingOverlay)
        SettingsLink { Text("Settings…") }

        Divider()

        Button("Quit vibe-meetings") { NSApp.terminate(nil) }
    }

    private var statusLine: String {
        let service = env.recordingService
        if let controller = service.controller {
            let title = controller.meetingHandle?.meeting.title ?? "meeting"
            switch controller.state {
            case .preparing: return "Starting “\(title)”…"
            case .error: return "Recording failed"
            default: return "Recording “\(title)” · \(controller.elapsed.formattedTimestamp)"
            }
        }
        if service.isStarting { return "Starting recording…" }
        if let call = env.bannerCoordinator.unrecordedCall {
            let what = env.bannerCoordinator.matchedEvent?.title ?? call.client.appName.map { "\($0) call" } ?? "Call"
            return "\(what) — not recording"
        }
        return "Not recording"
    }

    private var recordTitle: String {
        if let title = env.bannerCoordinator.matchedEvent?.title, env.bannerCoordinator.currentCall != nil {
            return "Record “\(title)”"
        }
        return "Record Now"
    }
}

/// Menu bar icon: idle waveform, an alert badge during an unrecorded call,
/// and a red dot + timer while recording.
struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let controller = env.recordingService.controller, controller.state == .recording {
                HStack(spacing: 4) {
                    Image(nsImage: Self.redRecordIcon)
                    Text(Self.shortTime(controller.elapsed)).monospacedDigit()
                }
            } else if env.bannerCoordinator.unrecordedCall != nil {
                Image(systemName: "exclamationmark.circle")
            } else {
                Image(systemName: "waveform")
            }
        }
        .onAppear {
            // Lets notification actions reopen the main window even if it was
            // closed before RootView ever registered.
            if env.presenter.openWindow == nil { env.presenter.openWindow = openWindow }
        }
    }

    /// Menu bar labels render as templates; a non-template image keeps the red.
    private static let redRecordIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()

    /// "12:04" / "1:02:33" — whole seconds only so the menu bar doesn't
    /// redraw more than it has to.
    private static func shortTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
