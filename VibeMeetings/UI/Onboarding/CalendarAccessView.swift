import SwiftUI
import EventKit
import VMCalendar

struct CalendarAccessView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Calendar (optional)", systemImage: "calendar").font(.title3.bold())

            row

            Text("Lets the app default a meeting's title to your event title, suggest recording when a Teams meeting starts, and route recurring meetings into the same folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .task { status = env.calendarService.authorizationStatus() }
    }

    @ViewBuilder
    private var row: some View {
        switch status {
        case .notDetermined:
            HStack {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                Text("Not yet requested")
                Spacer()
                Button("Request access") {
                    Task { status = await env.calendarService.requestAccess() }
                }
            }
        case .denied, .restricted, .writeOnly:
            HStack {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("Calendar access is off — calendar features disabled")
                Spacer()
                Button("Open System Settings…") { openCalendarSettings() }
            }
        case .fullAccess, .authorized:
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Calendar access granted")
                Spacer()
            }
        @unknown default:
            HStack {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                Text("Unknown status")
                Spacer()
                Button("Re-check") { status = env.calendarService.authorizationStatus() }
            }
        }
    }

    private func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
