import SwiftUI

/// Banner shown when the system microphone becomes active (another app like
/// Zoom or Teams started using it) while VibeMeetings is not recording.
struct MicActiveBanner: View {
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("**Microphone is in use** by another app")
                    .lineLimit(1)
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
