import SwiftUI
import VMCore
import VMCalendar
import VMStorage

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var calendarEvents: [CalendarEvent] = []
    let onSelectMeeting: (UUID) -> Void

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
            calendarEvents = await env.calendarService.upcomingEvents(within: 12 * 60 * 60)
        }
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

    // MARK: - Today's Schedule

    private var todaysScheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Today's Schedule", systemImage: "calendar")
                .font(.headline)

            if calendarEvents.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No upcoming meetings today")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 1) {
                    ForEach(calendarEvents) { event in
                        calendarEventRow(event)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func calendarEventRow(_ event: CalendarEvent) -> some View {
        let now = Date.now
        let isActive = event.startDate <= now && event.endDate > now

        return Button {
            NotificationCenter.default.post(name: .newMeetingRequested, object: nil)
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
                        Text(formatTimeRange(start: event.startDate, end: event.endDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if event.hasTeamsURL {
                            platformBadge("Teams", color: .purple)
                        }
                        if !event.attendeeNames.isEmpty {
                            Text("\(event.attendeeNames.count) attendees")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                if isActive {
                    Text("Now")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.15), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isActive ? Color.green.opacity(0.06) : Color(.controlBackgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func platformBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func formatTimeRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    // MARK: - Recent Meetings

    private var allMeetings: [Meeting] {
        guard let root = env.folderTree else { return [] }
        return collectAllMeetings(from: root)
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var recentMeetingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recent Meetings", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            let recent = Array(allMeetings.prefix(5))
            if recent.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No meetings yet")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 1) {
                    ForEach(recent) { meeting in
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
                                .foregroundStyle(.tertiary)
                        }
                        meetingTypeBadge(meeting.resolvedType)
                        if let org = meeting.org, !org.isEmpty {
                            Text(org)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.fill.tertiary, in: Capsule())
                        }
                    }
                }

                Spacer()

                if !hasSummary(for: meeting) {
                    Text("Needs summary")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.controlBackgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func meetingTypeBadge(_ type: MeetingType) -> some View {
        let label = type == .oneOnOne ? "1:1" : "Group"
        let color: Color = type == .oneOnOne ? .blue : .indigo
        return Text(label)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func formatDuration(_ ti: TimeInterval) -> String {
        let minutes = Int(ti) / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem > 0 ? "\(hours)h \(rem)m" : "\(hours)h"
    }

    // MARK: - Quick Stats

    private var quickStatsSection: some View {
        let meetings = allMeetings
        let calendar = Calendar.current
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let thisWeek = meetings.filter { $0.startedAt >= startOfWeek }

        let totalMinutes = thisWeek.compactMap(\.duration).reduce(0, +) / 60
        let pendingSummaries = meetings.filter { !hasSummary(for: $0) }.count
        let oneOnOnes = thisWeek.filter { $0.resolvedType == .oneOnOne }.count

        return HStack(spacing: 16) {
            statCard(
                title: "This Week",
                value: "\(thisWeek.count)",
                icon: "calendar.badge.clock",
                color: .blue
            )
            statCard(
                title: "Total Hours",
                value: String(format: "%.1f", Double(totalMinutes) / 60.0),
                icon: "clock",
                color: .green
            )
            statCard(
                title: "Pending Summaries",
                value: "\(pendingSummaries)",
                icon: "doc.text",
                color: pendingSummaries > 0 ? .orange : .secondary
            )
            statCard(
                title: "1:1s This Week",
                value: "\(oneOnOnes)",
                icon: "person.2",
                color: .purple
            )
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
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
    }

    // MARK: - Helpers

    private func collectAllMeetings(from node: FolderNode) -> [Meeting] {
        var result: [Meeting] = []
        if let meeting = node.meeting {
            result.append(meeting)
        }
        for child in node.children {
            result.append(contentsOf: collectAllMeetings(from: child))
        }
        return result
    }

    private func hasSummary(for meeting: Meeting) -> Bool {
        guard let root = env.folderTree else { return false }
        guard let node = findMeetingNode(id: meeting.id, in: root) else { return false }
        let summaryURL = node.url.appendingPathComponent(MeetingFolder.summaryFilename)
        return FileManager.default.fileExists(atPath: summaryURL.path)
    }

    private func findMeetingNode(id: UUID, in node: FolderNode) -> FolderNode? {
        if node.isMeeting, node.meeting?.id == id { return node }
        for child in node.children {
            if let hit = findMeetingNode(id: id, in: child) { return hit }
        }
        return nil
    }
}
