import SwiftUI
import AVFoundation

struct PermissionsView: View {
    @State private var micGranted: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Permissions", systemImage: "lock.shield").font(.title3.bold())

            HStack {
                Image(systemName: micGranted == true ? "checkmark.circle.fill" : "mic")
                    .foregroundStyle(micGranted == true ? .green : .orange)
                Text("Microphone")
                Spacer()
                if micGranted != true {
                    Button("Request") { Task { await requestMic() } }
                }
            }

            HStack {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.orange)
                Text("System audio (Core Audio Tap)")
                Spacer()
                Text("First recording will trigger the prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("If you deny system audio, only your microphone will be transcribed (you'll lose the other side of the call).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .task { micGranted = await AVCaptureDevice.requestAccess(for: .audio) }
    }

    private func requestMic() async {
        micGranted = await AVCaptureDevice.requestAccess(for: .audio)
    }
}
