import SwiftUI

/// Banner shown when the system microphone becomes active (another app like
/// Zoom or Teams started using it) while VibeMeetings is not recording.
struct MicActiveBanner: View {
    var eventTitle: String?
    var appName: String?
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                if let title = eventTitle {
                    Text("**\(title)** — microphone detected")
                        .lineLimit(1)
                } else if let app = appName {
                    Text("**\(app)** is using the microphone")
                        .lineLimit(1)
                } else {
                    Text("**Microphone is in use** by another app")
                        .lineLimit(1)
                }
                Text("It looks like a call may have started. Would you like to record?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Start recording", action: onStart)
                .buttonStyle(.borderedProminent)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.green.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
