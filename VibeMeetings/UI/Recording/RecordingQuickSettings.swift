import SwiftUI
import VMRecording

/// A gear that opens the settings you reach for right before recording —
/// microphone, echo removal, speaker detection, the floating indicator — without
/// a trip to Settings.
struct RecordingQuickSettingsButton: View {
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Recording settings")
        .accessibilityLabel("Recording settings")
        .popover(isPresented: $isShowing, arrowEdge: .top) {
            RecordingQuickSettings()
        }
    }
}

private struct RecordingQuickSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var inputDevices: [AudioInputDevice] = AudioDeviceEnumerator.inputDevices()

    /// Maps `nil` (system default) to the empty string the Picker needs.
    private var micSelection: Binding<String> {
        Binding(
            get: { env.selectedMicDeviceUID ?? "" },
            set: { env.setMicDevice(uid: $0.isEmpty ? nil : $0) }
        )
    }

    var body: some View {
        @Bindable var env = env
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Recording settings").font(.headline)

            Picker("Microphone", selection: micSelection) {
                Text("System Default").tag("")
                ForEach(inputDevices) { device in
                    Text(device.name + (device.isDefault ? " (Default)" : "")).tag(device.uid)
                }
            }

            Toggle("Remove speaker echo", isOn: $env.echoCancellationEnabled)
                .help("Cancels the other people's voices that your microphone picks up from your speakers")
            Toggle("Identify individual speakers", isOn: $env.speakerDetectionEnabled)
                .help("After each group call, split “Others” into Speaker 1, Speaker 2…")
            Toggle("Show floating indicator", isOn: $env.showRecordingOverlay)
            if env.showRecordingOverlay {
                Picker("Indicator size", selection: $env.recordingOverlaySize) {
                    ForEach(OverlaySizeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Divider()
            SettingsLink {
                Text("All settings…")
            }
        }
        .padding()
        .frame(width: 300)
    }
}
