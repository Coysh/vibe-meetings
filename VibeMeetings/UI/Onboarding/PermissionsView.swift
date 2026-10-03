import AVFoundation
import SwiftUI
import VMRecording

/// Onboarding step: microphone access. Explains first; only asks when the user
/// presses the button (the system prompt used to fire on launch with no context).
struct MicrophoneAccessStep: View {
    @State private var status = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vibe Meetings records your voice through your microphone, on your Mac. Nothing is uploaded.")
                .foregroundStyle(.secondary)

            switch status {
            case .authorized:
                Label("Microphone access is on", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notDetermined:
                Button("Allow microphone access") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        status = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
                .buttonStyle(.borderedProminent)
            default:
                Label("Microphone access is off", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Recording can't work without it. Turn it on in System Settings → Privacy & Security → Microphone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Microphone settings…") {
                    if let url = RecordingPermission.microphone.settingsURL { NSWorkspace.shared.open(url) }
                }
            }
        }
        // The user may flip the switch in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }
}

/// Onboarding step: system audio ("the other people on the call"). macOS only
/// shows this prompt the first time something taps system audio — which used to
/// be in the middle of someone's first real meeting.
struct SystemAudioAccessStep: View {
    private enum Result: Equatable {
        case untested, testing, working, failed(String)
    }
    @State private var result: Result = .untested

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("To transcribe the other people on your calls, Vibe Meetings listens to the audio your Mac is playing — Zoom, Teams, Meet and so on. macOS asks for permission once. Choose “Allow”.")
                .foregroundStyle(.secondary)

            switch result {
            case .untested:
                Button("Allow system audio") { Task { await test() } }
                    .buttonStyle(.borderedProminent)
            case .testing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…") }
            case .working:
                Label("System audio capture works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let reason):
                Label("Couldn't capture system audio", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Without it, only your own voice is recorded — the other side of calls will be missing. Allow “Vibe Meetings” under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(reason).font(.caption).foregroundStyle(.tertiary)
                HStack {
                    Button("Open settings…") {
                        if let url = RecordingPermission.systemAudio.settingsURL { NSWorkspace.shared.open(url) }
                    }
                    Button("Check again") { Task { await test() } }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if case .failed = result { Task { await test() } }
        }
    }

    /// Starts and immediately stops a system audio tap — enough to trigger the
    /// permission prompt and learn whether it was granted.
    private func test() async {
        result = .testing
        let failure: String? = await Task.detached {
            let tap = SystemAudioCapturer()
            do {
                try tap.start(epoch: 0)
                try? await Task.sleep(for: .milliseconds(500))
                tap.stop()
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        result = failure.map { .failed($0) } ?? .working
    }
}
