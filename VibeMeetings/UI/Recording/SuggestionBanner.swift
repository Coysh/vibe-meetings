import SwiftUI
import VMCalendar

struct SuggestionBanner: View {
    let event: CalendarEvent
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text("**\(event.title)** is starting on Teams")
                    .lineLimit(1)
                Text("Starts \(event.startDate.formatted(date: .omitted, time: .shortened)) · \(event.calendarTitle)")
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
        .background(.yellow.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
    }
}
