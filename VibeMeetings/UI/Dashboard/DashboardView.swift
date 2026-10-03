import EventKit
import SwiftUI
import VMCalendar
import VMCore
import VMStorage

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var calendarEvents: [CalendarEvent] = []
    @State private var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var stats = Stats()
    let onSelectMeeting: (UUID) -> Void

    /// Derived from the library once per change, not on every render. (It used to
    /// walk the whole tree and `stat()` a file per meeting inside `body`, several times.)
    private struct Stats {
        var recent: [Meeting] = []
        var meetingsThisWeek = 0
        var hoursThisWeek = 0.0
        var oneOnOnesThisWeek = 0
        var withoutSummary = 0
        var summaryIDs: Set<UUID> = []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                todaysScheduleSection
                recentMeetingsSection
                quickStatsSection
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task {
            // Keep the schedule current ("Now" badges go stale otherwise).
            while !Task.isCancelled {
                calendarStatus = env.calendarService.authorizationStatus()
                calendarEvents = await env.calendarService.upcomingEvents(within: 24 * 60 * 60)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: env.folderTree.map { ObjectIdentifier($0) }) { await recomputeStats() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.largeTitle.bold())
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    // MARK: - Today's schedule

    /// Events that start today and haven't finished.
    private var todaysEvents: [CalendarEvent] {
        let now = Date.now
        return calendarEvents
            .filter { Calendar.current.isDateInToday($0.startDate) && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    private var calendarAccessGranted: Bool {
        calendarStatus == .fullAccess || calendarStatus == .authorized
    }

    private var todaysScheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Today's schedule", systemImage: "calendar")
                .font(.headline)

            if !calendarAccessGranted {
                placeholder(
                    symbol: "calendar.badge.exclamationmark",
                    text: "Calendar access is off, so meetings can't be shown here."
                ) {
                    if calendarStatus == .notDetermined {
                        Button("Allow calendar access") {
                            Task { calendarStatus = await env.calendarService.requestAccess() }
                        }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        Button("Open Calendar settings…") { NSWorkspace.shared.open(url) }
                    }
                }
            } else if todaysEvents.isEmpty {
                placeholder(symbol: "calendar.badge.checkmark", text: "Nothing else on your calendar today") { EmptyView() }
            } else {
                VStack(spacing: 1) {
                    ForEach(todaysEvents) { event in
                        calendarEventRow(event)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func placeholder<Actions: View>(symbol: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(text)
                    .foregroundStyle(.secondary)
                actions()
            }
            .padding(.vertical, 20)
            Spacer()
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func calendarEventRow(_ event: CalendarEvent) -> some View {
        let now = Date.now
        let isActive = event.startDate <= now && event.endDate > now

        return Button {
            env.appRouter.requestNewMeeting(preselectEventID: event.id)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isActive ? Color.green : .blue)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        // Locale-aware: honours the user's 12/24-hour setting.
                        Text("\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        PlatformBadge(event: event)
                        if !event.attendeeNames.isEmpty {
                            Text("\(event.attendeeNames.count) attendees")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if isActive { Badge(text: "Now", color: .green) }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isActive ? Color.green.opacity(0.06) : Color(.controlBackgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Record “\(event.title)”")
    }

    // MARK: - Recent meetings

    private var recentMeetingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recent meetings", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if stats.recent.isEmpty {
                placeholder(symbol: "waveform.badge.mic", text: "No meetings yet") {
                    Button("Start a meeting") { env.appRouter.requestNewMeeting() }
                }
            } else {
                VStack(spacing: 1) {
                    ForEach(stats.recent) { meeting in
                        recentMeetingRow(meeting)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func recentMeetingRow(_ meeting: Meeting) -> some View {
        Button {
            onSelectMeeting(meeting.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let duration = meeting.duration {
                            Text(formatDuration(duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Badge(text: meeting.resolvedType.badgeLabel, color: meeting.resolvedType.badgeColor)
                        if let org = meeting.org, !org.isEmpty {
                            Badge(text: org)
                        }
                    }
                }

                Spacer()

                if !stats.summaryIDs.contains(meeting.id) {
                    Badge(text: "No summary", color: .orange)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.controlBackgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ ti: TimeInterval) -> String {
        let minutes = Int(ti) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem > 0 ? "\(hours)h \(rem)m" : "\(hours)h"
    }

    // MARK: - Quick stats

    private var quickStatsSection: some View {
        HStack(spacing: 16) {
            statCard(title: "Meetings this week", value: "\(stats.meetingsThisWeek)", icon: "calendar.badge.clock", color: .blue)
            statCard(title: "Hours this week", value: String(format: "%.1f", stats.hoursThisWeek), icon: "clock", color: .green)
            statCard(title: "1:1s this week", value: "\(stats.oneOnOnesThisWeek)", icon: "person.2", color: .purple)
            statCard(
                title: "Without a summary",
                value: "\(stats.withoutSummary)",
                icon: "doc.text",
                color: stats.withoutSummary > 0 ? .orange : .secondary
            )
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(value)
                .font(.title.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived data

    private func recomputeStats() async {
        guard let root = env.folderTree else { stats = Stats(); return }
        let nodes = root.allMeetingNodes
        // Disk checks off the main actor.
        let result: Stats = await Task.detached(priority: .userInitiated) {
            let startOfWeek = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
            var s = Stats()
            let sorted = nodes.compactMap { node in node.meeting.map { ($0, node.url) } }
                .sorted { $0.0.startedAt > $1.0.startedAt }
            let fm = FileManager.default
            for (meeting, url) in sorted {
                if fm.fileExists(atPath: url.appendingPathComponent(MeetingFolder.summaryFilename).path) {
                    s.summaryIDs.insert(meeting.id)
                }
            }
            s.recent = Array(sorted.prefix(5).map(\.0))
            let week = sorted.map(\.0).filter { $0.startedAt >= startOfWeek }
            s.meetingsThisWeek = week.count
            s.hoursThisWeek = week.compactMap(\.duration).reduce(0, +) / 3600
            s.oneOnOnesThisWeek = week.filter { $0.resolvedType == .oneOnOne }.count
            s.withoutSummary = sorted.count - s.summaryIDs.count
            return s
        }.value
        stats = result
    }
}
