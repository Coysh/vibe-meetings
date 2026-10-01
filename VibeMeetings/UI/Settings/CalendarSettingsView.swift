import SwiftUI
import EventKit
import VMCalendar

struct CalendarSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var calendars: [CalendarSummary] = []
    /// Local mirror of `CalendarPreferences.excludedCalendarIDs` so toggles
    /// redraw immediately (UserDefaults isn't observable).
    @State private var excluded: Set<String> = CalendarPreferences.shared.excludedCalendarIDs
    @State private var bannerEnabled: Bool = CalendarPreferences.shared.bannerEnabled
    @State private var filter = ""

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

            if calendars.isEmpty {
                Section("Calendars to watch") {
                    Text("Grant access above to see your calendars.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } else {
                Section {
                    TextField("Filter calendars", text: $filter)
                    Text("\(calendars.count - excluded.intersection(calendars.map(\.id)).count) of \(calendars.count) calendars watched for meetings and reminders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Calendars to watch")
                }

                ForEach(accounts, id: \.self) { account in
                    let cals = visibleCalendars(in: account)
                    if !cals.isEmpty {
                        Section {
                            ForEach(cals) { cal in
                                Toggle(cal.title, isOn: binding(for: cal))
                            }
                        } header: {
                            HStack {
                                Text(account)
                                Spacer()
                                Button("All") { setAll(cals, enabled: true) }
                                Button("None") { setAll(cals, enabled: false) }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }

            Section("Banner") {
                Toggle("Show meeting banner and calendar reminders", isOn: $bannerEnabled)
                    .onChange(of: bannerEnabled) { _, v in
                        CalendarPreferences.shared.bannerEnabled = v
                        env.eventReminders.setNeedsReconcile()
                    }
                Text("When an online meeting from your calendar is starting, show a one-click banner offering to start recording. The app never auto-starts recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await reloadCalendars() }
    }

    // MARK: - Calendars

    /// Account names (iCloud, Exchange, Google…), alphabetical.
    private var accounts: [String] {
        Array(Set(calendars.map(\.sourceTitle))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func visibleCalendars(in account: String) -> [CalendarSummary] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return calendars
            .filter { $0.sourceTitle == account }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || account.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func reloadCalendars() async {
        calendars = await env.calendarService.allCalendars()
        excluded = CalendarPreferences.shared.excludedCalendarIDs
    }

    private func binding(for cal: CalendarSummary) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(cal.id) },
            set: { enabled in setAll([cal], enabled: enabled) }
        )
    }

    private func setAll(_ cals: [CalendarSummary], enabled: Bool) {
        for cal in cals {
            if enabled { excluded.remove(cal.id) } else { excluded.insert(cal.id) }
        }
        CalendarPreferences.shared.excludedCalendarIDs = excluded
        // Reminders for newly (un)watched calendars update straight away.
        env.eventReminders.setNeedsReconcile()
    }

    // MARK: - Permission

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
}
