import SwiftUI
import EventKit
import VMCalendar

struct CalendarSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var calendars: [CalendarSummary] = []
    @State private var bannerEnabled: Bool = CalendarPreferences.shared.bannerEnabled

    var body: some View {
        Form {
            Section("Permission") {
                LabeledContent("Status") { Text(statusLabel) }
                if !isGranted {
                    Button("Request access") {
                        Task {
                            status = await env.calendarService.requestAccess()
                            await reloadCalendars()
                        }
                    }
                }
                if status == .denied || status == .restricted {
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section("Calendars to watch") {
                if calendars.isEmpty {
                    Text("Grant access above to see your calendars.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(calendars) { cal in
                        Toggle(isOn: binding(for: cal)) {
                            VStack(alignment: .leading) {
                                Text(cal.title)
                                Text(cal.sourceTitle).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Banner") {
                Toggle("Show Teams meeting banner", isOn: $bannerEnabled)
                    .onChange(of: bannerEnabled) { _, v in
                        CalendarPreferences.shared.bannerEnabled = v
                    }
                Text("When a Teams meeting from your calendar is starting, show a one-click banner offering to start recording. The app never auto-starts recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await reloadCalendars() }
    }

    private var isGranted: Bool {
        if #available(macOS 14, *) { return status == .fullAccess }
        return status == .authorized
    }

    private var statusLabel: String {
        switch status {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .writeOnly: return "Write-only (read denied)"
        case .fullAccess: return "Full access"
        case .authorized: return "Authorized"
        @unknown default: return "Unknown"
        }
    }

    private func reloadCalendars() async {
        calendars = await env.calendarService.allCalendars()
    }

    private func binding(for cal: CalendarSummary) -> Binding<Bool> {
        Binding(
            get: { !env.calendarService.isExcluded(cal.id) },
            set: { enabled in
                Task {
                    await env.calendarService.setExcluded(!enabled, for: cal.id)
                }
            }
        )
    }
}
