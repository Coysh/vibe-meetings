import EventKit
import SwiftUI
import VMCalendar

/// Onboarding step: optional calendar access and notification permission, both
/// explained before being requested.
struct CalendarAndNotificationsStep: View {
    @Environment(AppEnvironment.self) private var env
    @State private var calendar: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var notificationsRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Calendar (optional)", systemImage: "calendar").font(.headline)
                Text("Names recordings after your calendar events, reminds you before a meeting with a join link, and files recurring meetings together.")
                    .font(.callout).foregroundStyle(.secondary)
                calendarRow
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Notifications (recommended)", systemImage: "bell").font(.headline)
                Text("Lets Vibe Meetings tell you when a call starts that isn't being recorded, and when a recording has finished. Reminders work best with the alert style set to “Alerts” in System Settings → Notifications.")
                    .font(.callout).foregroundStyle(.secondary)
                if notificationsRequested {
                    Label("Done — you can adjust these in System Settings", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Allow notifications") {
                        Task {
                            await env.notifications.ensureAuthorized()
                            notificationsRequested = true
                        }
                    }
                }
            }
        }
        .task { calendar = env.calendarService.authorizationStatus() }
    }

    @ViewBuilder
    private var calendarRow: some View {
        switch calendar {
        case .notDetermined:
            Button("Allow calendar access") {
                Task { calendar = await env.calendarService.requestAccess() }
            }
        case .fullAccess, .authorized:
            Label("Calendar access is on", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            Label("Calendar access is off — calendar features are disabled", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange)
            Button("Open Calendar settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
