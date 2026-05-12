import SwiftUI

/// Banner shown when the meeting has likely ended — triggered by calendar time,
/// extended audio silence, or meeting app exit.
struct MeetingEndBanner: View {
    let reason: String
    let onStop: () -> Void
    let onKeep: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("**\(reason.isEmpty ? "Meeting may have ended" : reason)**")
                    .lineLimit(1)
                Text("Would you like to stop recording?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Stop recording", action: onStop)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            Button("Keep recording", action: onKeep)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
