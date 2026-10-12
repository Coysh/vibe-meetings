import EventKit
import SwiftUI
import VMCalendar
import VMCore
import VMStorage

/// Home: a greeting, what's coming up on the calendar, the last few meetings and
/// a quiet row of this week's numbers.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var stats = Stats()
    /// From `RootView`, which refreshes the calendar once for every page.
    let upcoming: [CalendarEvent]
    let onSelectMeeting: (UUID) -> Void

    /// Derived from the library once per change, not on every render. (It used to
    /// walk the whole tree and `stat()` a file per meeting inside `body`, several times.)
    private struct Stats {
        var recent: [MeetingItem] = []
        var meetingsThisWeek = 0
        var hoursThisWeek = 0.0
        var oneOnOnesThisWeek = 0
        var withoutSummary = 0
        var summaryIDs: Set<UUID> = []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
                headerSection
                comingUpSection
                recentMeetingsSection
                quickStatsSection
            }
            .padding(.top, Tokens.Space.xl)
            .padding(.bottom, Tokens.Space.xxl)
            .readableWidth()
            .padding(.horizontal, Tokens.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface)
        .floatingActionBar()
        .task {
            // Keep the access state current (the "Allow calendar access" prompt goes stale otherwise).
            while !Task.isCancelled {
                calendarStatus = env.calendarService.authorizationStatus()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: env.folderTree.map { ObjectIdentifier($0) }) { await recomputeStats() }
    }

    // MARK: - Header

    private var headerSection: some View {
        PageHeader(
            title: greeting,
            subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        ) {
            HStack(spacing: Tokens.Space.m) {
                RecordingQuickSettingsButton()
                Button {
                    env.appRouter.requestNewMeeting()
                } label: {
                    Label("Start Recording", systemImage: "mic.fill")
                }
                .buttonStyle(.capsule(.primary))
                .help("Start a new meeting (⌘N)")
            }
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

    // MARK: - Coming up

    /// Events that haven't finished, soonest first.
    private var comingUp: [CalendarEvent] {
        upcoming
            .filter { $0.endDate > .now }
            .sorted { $0.startDate < $1.startDate }
    }

    private var calendarAccessGranted: Bool {
        calendarStatus == .fullAccess || calendarStatus == .authorized
    }

    private var comingUpSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            SectionHeader(title: "Coming up")

            if !calendarAccessGranted {
                placeholder(
                    symbol: "calendar.badge.exclamationmark",
                    text: "Calendar access is off, so meetings can't be shown here."
                ) {
                    if calendarStatus == .notDetermined {
                        Button("Allow calendar access") {
                            Task { calendarStatus = await env.calendarService.requestAccess() }
                        }
                        .buttonStyle(.capsule(.secondary))
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        Button("Open Calendar settings…") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.capsule(.secondary))
                    }
                }
            } else if comingUp.isEmpty {
                placeholder(symbol: "calendar.badge.checkmark", text: "Nothing coming up on your calendar") { EmptyView() }
            } else {
                ForEach(comingUp.prefix(3)) { event in
                    UpcomingEventCard(event: event)
                }
            }
        }
    }

    private func placeholder<Actions: View>(symbol: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: Tokens.Space.s) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Space.l)
        .card()
    }

    // MARK: - Recent meetings

    private var recentMeetingsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            SectionHeader(title: "Recent")

            if stats.recent.isEmpty {
                placeholder(symbol: "waveform.badge.mic", text: "No meetings yet") {
                    Button("Start a meeting") { env.appRouter.requestNewMeeting() }
                        .buttonStyle(.capsule(.secondary))
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(stats.recent) { item in
                        Button {
                            onSelectMeeting(item.id)
                        } label: {
                            MeetingRow(
                                item: item,
                                showsDate: true,
                                flag: stats.summaryIDs.contains(item.id) ? nil : "No summary"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Quick stats

    private var quickStatsSection: some View {
        HStack(spacing: 0) {
            statCell(value: "\(stats.meetingsThisWeek)", label: "meetings this week")
            statDivider
            statCell(value: String(format: "%.1f", stats.hoursThisWeek), label: "hours this week")
            statDivider
            statCell(value: "\(stats.oneOnOnesThisWeek)", label: "1:1s this week")
            statDivider
            statCell(
                value: "\(stats.withoutSummary)",
                label: "without a summary",
                tint: stats.withoutSummary > 0 ? .orange : nil
            )
        }
        .padding(.vertical, Tokens.Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.stroke).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.stroke).frame(height: 1) }
    }

    private var statDivider: some View {
        Rectangle().fill(Tokens.stroke).frame(width: 1, height: 28)
    }

    private func statCell(value: String, label: String, tint: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(tint ?? .primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived data

    private func recomputeStats() async {
        guard let root = env.folderTree else { stats = Stats(); return }
        let nodes = root.allMeetingNodes
        let rootName = root.name
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
            s.recent = sorted.prefix(5).map { meeting, url in
                let folderName = url.deletingLastPathComponent().lastPathComponent
                return MeetingItem(meeting: meeting, folderURL: url, folderName: folderName.isEmpty ? rootName : folderName)
            }
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
