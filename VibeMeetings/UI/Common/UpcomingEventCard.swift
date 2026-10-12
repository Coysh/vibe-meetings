import SwiftUI
import VMCalendar
import VMCore

/// A calendar event as a card: a big day number, a bar that's red while it's on,
/// the title and time, and the buttons to record it.
struct UpcomingEventCard: View {
    let event: CalendarEvent
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let now = Date.now
        let isNow = event.startDate <= now && event.endDate > now

        HStack(spacing: Tokens.Space.l) {
            HStack(alignment: .center, spacing: 6) {
                Text(event.startDate, format: .dateTime.day())
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.startDate, format: .dateTime.month(.abbreviated))
                    Text(event.startDate, format: .dateTime.weekday(.abbreviated))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Capsule()
                .fill(isNow ? Tokens.record : Color.accentColor)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title).font(Tokens.rowTitle).lineLimit(1)
                    PlatformBadge(event: event)
                    if isNow { Badge(text: "Now", color: Tokens.record) }
                }
                // Locale-aware: honours the user's 12/24-hour setting.
                Text("\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(Tokens.secondary)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Tokens.Space.m)

            if event.hasMeetingLink {
                Button {
                    Task { await env.recordingService.joinAndRecord(event: event) }
                } label: {
                    Label("Join & Record", systemImage: "video.fill")
                }
                .buttonStyle(.capsule(.primary))
                .help("Open the meeting link and start recording")
            }
            Button {
                Task { await env.recordingService.start(event: event) }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.capsule(.secondary))
            .help("Start recording “\(event.title)” now")
        }
        .card()
        .accessibilityElement(children: .contain)
    }
}
