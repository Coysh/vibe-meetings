import SwiftUI
import VMCore
import VMStorage

/// Search every meeting: titles and people, summaries, notes, write-ups and
/// transcripts, ranked, with the matching passages shown under each meeting.
/// Clicking a passage opens the meeting there.
struct SearchView: View {
    let onOpen: (MeetingRoute) -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var itemsByID: [UUID: MeetingItem] = [:]
    @State private var pageWidth: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    private var search: SearchService { env.searchService }

    /// Side margin that centres the content at the reading width in a wide window.
    private var pageMargin: CGFloat {
        max(24, (pageWidth - Tokens.readingWidth) / 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                PageHeader(title: "Search", subtitle: subtitle) { sortMenu }
                field
                SearchFilterBar(filters: Binding(get: { search.query.filters }, set: { search.query.filters = $0 }))
                statusBanner
            }
            .padding(.horizontal, pageMargin + 12)
            .padding(.top, Tokens.Space.xl)
            .padding(.bottom, Tokens.Space.s)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .task(id: env.folderTree.map { ObjectIdentifier($0) }) { rebuildItems() }
        .onChange(of: env.appRouter.pendingSearchFocus) { consumeFocusRequest() }
        .onAppear {
            consumeFocusRequest()
            if search.query.isBlank { fieldFocused = true }
        }
    }

    // MARK: - Header

    private var subtitle: String? {
        guard !search.query.isBlank else { return nil }
        let n = visibleHits.count
        return "\(n) meeting\(n == 1 ? "" : "s")"
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(get: { search.query.sort }, set: { search.query.sort = $0 })) {
                Text("Best match").tag(SearchQuery.Sort.relevance)
                Text("Newest first").tag(SearchQuery.Sort.newest)
            }
            .pickerStyle(.inline)
        } label: {
            Chip(text: search.query.sort == .relevance ? "Best match" : "Newest first",
                 systemImage: "arrow.up.arrow.down", showsChevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Sort the results")
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search titles, people, summaries and transcripts…",
                      text: Binding(get: { search.query.text }, set: { search.query.text = $0 }))
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .accessibilityLabel("Search meetings")
                .onExitCommand { search.query.text = "" }
            if search.isSearching {
                ProgressView().controlSize(.mini)
            }
            if !search.query.text.isEmpty {
                Button { search.query.text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous).strokeBorder(Tokens.stroke))
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let progress = search.indexing {
            HStack(spacing: Tokens.Space.m) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 90)
                Text("Indexing meetings: \(progress.done) of \(progress.total)")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.callout)
        } else if let error = search.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    // MARK: - Results

    /// Hits for meetings that are still in the library (the index can trail a move or delete by a moment).
    private var visibleHits: [SearchHit] {
        search.results.hits.filter { itemsByID[$0.meetingID] != nil }
    }

    @ViewBuilder
    private var content: some View {
        let hits = visibleHits
        if search.query.isBlank {
            ContentUnavailableView {
                Label("Search your meetings", systemImage: "magnifyingglass")
            } description: {
                Text("Words are found in titles, people, summaries, notes, write-ups and transcripts — “signed” finds “sign” and “signing” too. Put a phrase in \"quotes\", and use -word to leave a word out. Or just pick filters to list meetings.")
            }
        } else if hits.isEmpty {
            if search.isSearching || (!search.isReady && search.indexing != nil) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.query.hasWords {
                ContentUnavailableView.search(text: search.query.text)
            } else {
                ContentUnavailableView("No meetings match these filters", systemImage: "line.3.horizontal.decrease.circle")
            }
        } else {
            List {
                ForEach(hits) { hit in
                    if let item = itemsByID[hit.meetingID] {
                        SearchResultRow(item: item, hit: hit) { focus in
                            onOpen(MeetingRoute(id: hit.meetingID, focus: focus))
                        }
                        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                        .listRowSeparator(.hidden)
                        .contextMenu { MeetingContextMenu(meeting: item.meeting, folderURL: item.folderURL) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, pageMargin, for: .scrollContent)
        }
    }

    // MARK: - Helpers

    private func rebuildItems() {
        guard let root = env.folderTree else { itemsByID = [:]; return }
        var out: [UUID: MeetingItem] = [:]
        func collect(_ node: FolderNode, folderName: String) {
            if node.isMeeting, let meeting = node.meeting, out[meeting.id] == nil {
                out[meeting.id] = MeetingItem(meeting: meeting, folderURL: node.url, folderName: folderName)
            }
            for child in node.children {
                collect(child, folderName: node.isMeeting ? folderName : (node === root ? "" : node.name))
            }
        }
        collect(root, folderName: "")
        itemsByID = out
    }

    private func consumeFocusRequest() {
        guard env.appRouter.pendingSearchFocus else { return }
        env.appRouter.pendingSearchFocus = false
        Task { @MainActor in fieldFocused = true }
    }
}
