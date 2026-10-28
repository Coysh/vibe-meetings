import SwiftUI
import VMCalendar
import VMCore
import VMStorage

/// One meeting as the list sees it, with everything its row shows worked out
/// in advance (the row must not walk the tree or format strings on every render).
struct MeetingItem: Identifiable {
    let meeting: Meeting
    /// The meeting's own folder, where its files live.
    let folderURL: URL
    /// The folder it's filed in.
    let folderName: String
    /// Who was there; falls back to the organisation, then the folder.
    let subtitle: String
    var id: UUID { meeting.id }

    init(meeting: Meeting, folderURL: URL, folderName: String) {
        self.meeting = meeting
        self.folderURL = folderURL
        self.folderName = folderName
        self.subtitle = Self.subtitle(for: meeting, folderName: folderName)
    }

    private static func subtitle(for meeting: Meeting, folderName: String) -> String {
        let attendees = (meeting.attendees ?? []).filter { !$0.isEmpty }
        if !attendees.isEmpty { return attendees.joined(separator: ", ") }
        // Named speakers (found by speaker detection or renamed by hand), not the stock labels.
        let named = meeting.participants.map(\.displayName).filter { name in
            let lower = name.lowercased()
            return !lower.isEmpty && lower != "you" && lower != "imported"
                && !lower.hasPrefix("others") && !lower.hasPrefix("speaker")
        }
        if !named.isEmpty { return named.joined(separator: ", ") }
        if let org = meeting.org, !org.isEmpty { return org }
        return folderName
    }
}

private struct DaySection: Identifiable {
    let day: Date
    let title: String
    let items: [MeetingItem]
    var id: Date { day }
}

/// All meetings, or the meetings in one folder, newest first and grouped by day —
/// "Today", "Yesterday", then "16 June 2026". Clicking a row opens the meeting.
struct MeetingListView: View {
    enum Scope: Hashable {
        case all
        /// Meetings not filed in any folder.
        case inbox
        case folder(URL)

        var isFolder: Bool {
            if case .folder = self { return true }
            return false
        }
    }

    let scope: Scope
    let upcoming: [CalendarEvent]
    /// Re-read the calendar now (the "Next up" refresh button).
    var onRefreshCalendar: () -> Void = {}
    let onOpen: (UUID) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryActions.self) private var library

    @State private var items: [MeetingItem] = []
    @State private var itemsByID: [UUID: MeetingItem] = [:]
    @State private var sections: [DaySection] = []
    @State private var selection: Set<UUID> = []
    /// "Select" mode: rows get checkboxes and a click ticks a meeting instead of opening it.
    @State private var isSelecting = false
    @State private var pageWidth: CGFloat = 0

    /// Side margin that centres the content at the reading width in a wide window.
    private var pageMargin: CGFloat {
        max(24, (pageWidth - Tokens.readingWidth) / 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                header
                selectionBar
                ImproveProgressBanner()
                nextUp
            }
            .padding(.horizontal, pageMargin + 12)
            .padding(.top, Tokens.Space.xl)
            .padding(.bottom, Tokens.Space.s)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface)
        .floatingActionBar()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .task(id: env.folderTree.map { ObjectIdentifier($0) }) { rebuildIndex() }
        // Once the run starts, the banner shows its progress; leave select mode.
        .onChange(of: env.refinementService.bulk != nil) { _, running in
            if running { endSelecting() }
        }
    }

    // MARK: - Header

    private var title: String {
        switch scope {
        case .all: return "Meetings"
        case .inbox: return "Inbox"
        case .folder(let url):
            let name = env.folderTree?.node(at: url)?.name ?? url.lastPathComponent
            return [FolderIcon.read(in: url), name].compactMap { $0 }.joined(separator: " ")
        }
    }

    private var subtitle: String? {
        if case .all = scope { return nil }
        return "\(items.count) meeting\(items.count == 1 ? "" : "s")"
    }

    private var header: some View {
        PageHeader(title: title, subtitle: subtitle) {
            HStack(spacing: Tokens.Space.m) {
                RecordingQuickSettingsButton()

                Button(action: openSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(scope.isFolder ? "Search this folder (⌥⌘F searches everything)" : "Search meetings (⌥⌘F)")
                .accessibilityLabel("Search meetings")

                Button {
                    if isSelecting { endSelecting() } else { isSelecting = true }
                } label: {
                    Image(systemName: "checklist")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelecting ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
                .help("Select meetings, to improve their transcripts")
                .accessibilityLabel("Select meetings")

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

    // MARK: - Select mode

    /// The meetings on screen whose transcript hasn't been improved and could be.
    private var notImprovedIDs: Set<UUID> {
        Set(sections.lazy.flatMap(\.items)
            .filter { $0.meeting.hasAudio && $0.meeting.endedAt != nil && !env.refinementService.isImproved($0.id) }
            .map(\.id))
    }

    @ViewBuilder
    private var selectionBar: some View {
        if isSelecting {
            let toImprove = selection.intersection(notImprovedIDs).count
            let running = env.refinementService.bulk != nil
            HStack(spacing: Tokens.Space.m) {
                Text(selection.isEmpty ? "Tick the meetings to improve" : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
                Spacer(minLength: Tokens.Space.m)
                Button("Select not improved") { selection = notImprovedIDs }
                    .disabled(notImprovedIDs.isEmpty)
                    .help("Tick every meeting on screen that hasn't had its transcript improved")
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }
                }
                Button {
                    requestImprove()
                } label: {
                    Label(toImprove > 0 ? "Improve \(toImprove) transcript\(toImprove == 1 ? "" : "s")…" : "Improve transcripts…",
                          systemImage: "sparkles")
                }
                .buttonStyle(.capsule(.primary))
                .disabled(toImprove == 0 || running)
                .help(running ? "Transcripts are already being improved" : "Transcribe the ticked recordings again with a larger model")
                Button("Done") { endSelecting() }
            }
            .font(.callout)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.s)
            .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous).strokeBorder(Tokens.stroke))
        }
    }

    private func requestImprove() {
        let targets = selection.compactMap { itemsByID[$0] }.map { (meeting: $0.meeting, folder: $0.folderURL) }
        let plan = TranscriptRefinementService.plan(for: targets)
        if !plan.meetings.isEmpty { library.improveRequest = plan }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// The calendar events that haven't finished — only on the all-meetings page.
    @ViewBuilder
    private var nextUp: some View {
        if scope == .all {
            NextUpSection(events: upcoming, onRefresh: onRefreshCalendar)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySymbol)
            } description: {
                Text(emptyDescription)
            } actions: {
                Button("Start Recording") { env.appRouter.requestNewMeeting() }
                    .buttonStyle(.capsule(.primary))
            }
        } else {
            list
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .all: "No meetings yet"
        case .inbox: "Your inbox is empty"
        case .folder: "This folder is empty"
        }
    }

    private var emptySymbol: String {
        switch scope {
        case .all: "waveform.badge.mic"
        case .inbox: "tray"
        case .folder: "folder"
        }
    }

    private var emptyDescription: String {
        switch scope {
        case .all: "Start a meeting with ⌘N, or from the menu bar."
        case .inbox: "Meetings that aren't filed in a folder show up here."
        case .folder: "Meetings you record or move here will appear in this list."
        }
    }

    private var list: some View {
        List(selection: listSelection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        MeetingRow(item: item, isChecked: isSelecting ? selection.contains(item.id) : nil)
                            .tag(item.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                            .listRowSeparator(.hidden)
                            // On mouse-up, so a drag onto a sidebar folder isn't an open.
                            .onTapGesture { isSelecting ? toggle(item.id) : openFromClick(item.id) }
                            .draggable(item.id.uuidString)
                    }
                } header: {
                    SectionHeader(title: section.title)
                        .padding(.top, Tokens.Space.l)
                        .padding(.leading, 12)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, pageMargin, for: .scrollContent)
        .contextMenu(forSelectionType: UUID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            if !isSelecting, ids.count == 1, let id = ids.first { onOpen(id) }
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            library.bulkDelete = selection.map { .meeting(id: $0) }
        }
    }

    /// The list's own selection (⌘/⇧-click); in select mode ticks are managed by hand instead.
    private var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { isSelecting ? [] : selection },
            set: { if !isSelecting { selection = $0 } }
        )
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<UUID>) -> some View {
        if ids.count == 1, let id = ids.first, let item = itemsByID[id] {
            MeetingContextMenu(meeting: item.meeting, folderURL: item.folderURL)
        } else if ids.count > 1 {
            ImproveTranscriptsMenuItem(targets: ids.compactMap { itemsByID[$0] }.map { (meeting: $0.meeting, folder: $0.folderURL) })
            Divider()
            Button("Delete \(ids.count) Meetings…", role: .destructive) {
                library.bulkDelete = ids.map { .meeting(id: $0) }
            }
        }
    }

    /// A plain click opens the meeting; ⌘/⇧-click is the list's multi-select.
    private func openFromClick(_ id: UUID) {
        guard NSEvent.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return }
        selection = []
        onOpen(id)
    }

    // MARK: - Index

    /// The meetings in scope, newest first. Rebuilt when the library changes —
    /// never inside `body`.
    private func rebuildIndex() {
        guard let root = env.folderTree else {
            items = []; itemsByID = [:]; sections = []
            return
        }
        let base: FolderNode
        switch scope {
        case .all, .inbox: base = root
        case .folder(let url): base = root.node(at: url) ?? root
        }
        var built: [MeetingItem] = []
        collect(from: base, folderName: base.isMeeting ? "" : base.name, into: &built)
        if case .inbox = scope {
            let rootURL = root.url.standardizedFileURL
            built.removeAll { $0.folderURL.deletingLastPathComponent().standardizedFileURL != rootURL }
        }
        built.sort { $0.meeting.startedAt > $1.meeting.startedAt }
        items = built
        itemsByID = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rebuildSections()
    }

    private func collect(from node: FolderNode, folderName: String, into out: inout [MeetingItem]) {
        if node.isMeeting, let meeting = node.meeting {
            out.append(MeetingItem(meeting: meeting, folderURL: node.url, folderName: folderName))
        }
        for child in node.children {
            collect(from: child, folderName: node.isMeeting ? folderName : node.name, into: &out)
        }
    }

    private func rebuildSections() {
        sections = Self.group(items)
    }

    /// `items` is newest first, so consecutive meetings on the same day share a section.
    private static func group(_ items: [MeetingItem]) -> [DaySection] {
        let calendar = Calendar.current
        var result: [DaySection] = []
        var currentDay: Date?
        var bucket: [MeetingItem] = []

        func flush() {
            guard let day = currentDay, !bucket.isEmpty else { return }
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = day.formatted(.dateTime.day().month(.wide).year())
            }
            result.append(DaySection(day: day, title: title, items: bucket))
            bucket = []
        }

        for item in items {
            let day = calendar.startOfDay(for: item.meeting.startedAt)
            if day != currentDay {
                flush()
                currentDay = day
            }
            bucket.append(item)
        }
        flush()
        return result
    }

    // MARK: - Search

    /// Opens the Search page; from a folder, it's limited to that folder.
    private func openSearch() {
        if case .folder(let url) = scope, let root = env.folderTree {
            env.searchService.scope(toFolder: root.node(at: url)?.displayPath(relativeTo: root.url))
        }
        env.appRouter.pendingSearchFocus = true
        env.appRouter.showSearchPage = true
    }
}

/// One line of the list: title and who was there on the left, the time on the right.
struct MeetingRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: MeetingItem
    /// Home shows recent meetings from several days, so its rows say which day.
    var showsDate = false
    /// A small orange tag before the time ("No summary").
    var flag: String? = nil
    /// In select mode, whether this row is ticked; nil when not selecting.
    var isChecked: Bool? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
            if let isChecked {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                    .imageScale(.large)
                    .accessibilityLabel(isChecked ? "Selected" : "Not selected")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.meeting.title)
                    .font(Tokens.rowTitle)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(Tokens.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.Space.m)
            if let flag { Badge(text: flag, color: .orange) }
            transcriptState
            Group {
                if showsDate {
                    Text(item.meeting.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                } else {
                    Text(item.meeting.startedAt, format: .dateTime.hour().minute())
                }
            }
            .font(Tokens.secondary)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .hoverHighlight()
        .accessibilityElement(children: .combine)
    }

    /// A sparkle once the transcript has been transcribed again from the recording; a spinner while that's happening.
    @ViewBuilder
    private var transcriptState: some View {
        let service = env.refinementService
        if service.isActive(item.id) {
            ProgressView().controlSize(.mini)
                .help("Improving this transcript…")
                .accessibilityLabel("Improving transcript")
        } else if service.isImproved(item.id) {
            Image(systemName: "sparkles")
                .font(Tokens.secondary)
                .foregroundStyle(Color.accentColor)
                .help("Transcript improved: transcribed again from the recording")
                .accessibilityLabel("Transcript improved")
        }
    }
}

/// Progress of an "improve transcripts" run over several meetings, and how the last one ended.
private struct ImproveProgressBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let service = env.refinementService
        if let progress = service.bulk {
            banner {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 90)
                Text("Improving transcripts: \(progress.done) of \(progress.total) — \(progress.current)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Tokens.Space.m)
                Button("Stop") { service.cancelBulk() }.controlSize(.small)
            }
        } else if let summary = service.bulkSummary {
            banner {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(summary).foregroundStyle(.secondary)
                Spacer(minLength: Tokens.Space.m)
                Button { service.dismissBulkSummary() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Tokens.Space.m) { content() }
            .font(.callout)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.s)
            .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous).strokeBorder(Tokens.stroke))
    }
}

/// "Next up": the calendar's coming events, a page of five at a time, with a
/// refresh button and a filter. Shows the first event; "Show more" opens the page.
private struct NextUpSection: View {
    let events: [CalendarEvent]
    let onRefresh: () -> Void

    private static let pageSize = 5
    @AppStorage("VibeMeetings.NextUp.LinksOnly") private var linksOnly = false
    @State private var page = 0
    @State private var expanded = false

    private var filtered: [CalendarEvent] {
        events
            .filter { $0.endDate > .now && (!linksOnly || $0.hasMeetingLink) }
            .sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        let all = filtered
        let pageCount = max(1, Int((Double(all.count) / Double(Self.pageSize)).rounded(.up)))
        let current = min(page, pageCount - 1)
        let start = current * Self.pageSize
        let pageEvents = Array(all.dropFirst(start).prefix(Self.pageSize))

        if !all.isEmpty || linksOnly {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                HStack(spacing: Tokens.Space.m) {
                    SectionHeader(title: "Next up")
                    Spacer()
                    if !all.isEmpty {
                        pager(start: start, shown: pageEvents.count, total: all.count, current: current, pageCount: pageCount)
                    }
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh from your calendar")
                    .accessibilityLabel("Refresh calendar")

                    Menu {
                        Toggle("Only meetings with a join link", isOn: $linksOnly)
                    } label: {
                        Image(systemName: linksOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .foregroundStyle(linksOnly ? Color.accentColor : .secondary)
                    .fixedSize()
                    .help("Filter")
                    .accessibilityLabel("Filter upcoming meetings")
                }

                if let first = pageEvents.first {
                    UpcomingEventCard(event: first)
                    if expanded {
                        ForEach(pageEvents.dropFirst()) { UpcomingEventCard(event: $0) }
                    }
                    if pageEvents.count > 1 {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                        } label: {
                            Label(expanded ? "Show less" : "Show more",
                                  systemImage: expanded ? "chevron.up" : "chevron.down")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("No upcoming meetings with a join link.")
                        .font(Tokens.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: linksOnly) { page = 0 }
        }
    }

    /// "‹ 1–5 of 12 ›"
    private func pager(start: Int, shown: Int, total: Int, current: Int, pageCount: Int) -> some View {
        HStack(spacing: 6) {
            Button { page = max(0, current - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(current == 0)
                .accessibilityLabel("Previous page")
            Text("\(start + 1)–\(start + shown) of \(total)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { page = min(pageCount - 1, current + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(current >= pageCount - 1)
                .accessibilityLabel("Next page")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
