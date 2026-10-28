import SwiftUI
import VMCore
import VMStorage

/// The Search page's filters, one chip each: date, folder, people, organisation,
/// type, labels, improved transcripts, where to look and who said it. A chip
/// with a value is tinted; each menu starts with an item that clears it.
struct SearchFilterBar: View {
    @Binding var filters: SearchFilters

    @Environment(AppEnvironment.self) private var env
    @State private var showCustomDates = false
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customTo = Date.now
    @State private var showPeople = false
    @State private var showSpeakers = false

    private var facets: SearchFacets { env.searchService.facets }

    var body: some View {
        FlowLayout(spacing: Tokens.Space.s) {
            dateChip
            folderChip
            peopleChip
            if !facets.orgs.isEmpty || filters.org != nil { orgChip }
            typeChip
            if !facets.labels.isEmpty || !filters.labels.isEmpty { labelsChip }
            improvedChip
            kindsChip
            speakerChip
            if !filters.isEmpty {
                Button("Clear filters") { filters = SearchFilters() }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 5)
            }
        }
    }

    // MARK: - Date

    private var dateChip: some View {
        Menu {
            Button("Any time") { filters.dateRange = nil }
            Divider()
            Button("Past week") { filters.dateRange = .pastWeek }
            Button("Past month") { filters.dateRange = .pastMonth }
            Button("Past 3 months") { filters.dateRange = .pastThreeMonths }
            Button("This year") { filters.dateRange = .thisYear }
            Divider()
            Button("Custom range…") { showCustomDates = true }
        } label: {
            chip(dateLabel, systemImage: "calendar", isActive: filters.dateRange != nil)
        }
        .chipMenu()
        .popover(isPresented: $showCustomDates, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                Text("Meetings between").font(.headline)
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("To", selection: $customTo, displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("Cancel") { showCustomDates = false }
                    Button("Apply") {
                        filters.dateRange = .custom(from: customFrom, to: customTo)
                        showCustomDates = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 280)
        }
    }

    private var dateLabel: String {
        switch filters.dateRange {
        case nil: "Any time"
        case .pastWeek?: "Past week"
        case .pastMonth?: "Past month"
        case .pastThreeMonths?: "Past 3 months"
        case .thisYear?: "This year"
        case .custom(let from, let to)?:
            "\(from.formatted(.dateTime.day().month(.abbreviated))) – \(to.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }

    // MARK: - Folder

    private var folderChip: some View {
        Menu {
            Button("Any folder") { filters.folderPath = nil }
            Divider()
            ForEach(folderPaths, id: \.self) { path in
                Button(path) { filters.folderPath = path }
            }
        } label: {
            chip(filters.folderPath ?? "Any folder", systemImage: "folder", isActive: filters.folderPath != nil)
        }
        .chipMenu()
    }

    /// Every folder below the root, as "Clients/Acme".
    private var folderPaths: [String] {
        guard let root = env.folderTree else { return [] }
        return root.allFolders
            .filter { $0 !== root }
            .map { $0.displayPath(relativeTo: root.url) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - People, organisation, labels, speaker

    private var peopleChip: some View {
        Button { showPeople = true } label: {
            chip(summary(of: filters.people, empty: "Anyone"), systemImage: "person.2", isActive: !filters.people.isEmpty, chevron: true)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPeople, arrowEdge: .bottom) {
            FacetPicker(title: "People", values: facets.people, selection: $filters.people, allowsMany: true)
        }
        .help("Meetings with any of these people")
    }

    private var orgChip: some View {
        Menu {
            Button("Any organisation") { filters.org = nil }
            Divider()
            ForEach(facets.orgs) { org in
                Button("\(org.name) (\(org.count))") { filters.org = org.name }
            }
        } label: {
            chip(filters.org ?? "Any organisation", systemImage: "building.2", isActive: filters.org != nil)
        }
        .chipMenu()
    }

    private var labelsChip: some View {
        Menu {
            Button("Any label") { filters.labels = [] }
            Divider()
            ForEach(facets.labels) { label in
                Toggle("\(label.name) (\(label.count))", isOn: membership(label.name, in: $filters.labels))
            }
        } label: {
            chip(summary(of: filters.labels, empty: "Any label"), systemImage: "tag", isActive: !filters.labels.isEmpty)
        }
        .chipMenu()
    }

    private var speakerChip: some View {
        Button { showSpeakers = true } label: {
            chip(filters.speaker.map { "Said by \($0)" } ?? "Anyone speaking", systemImage: "quote.bubble",
                 isActive: filters.speaker != nil, chevron: true)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSpeakers, arrowEdge: .bottom) {
            FacetPicker(title: "Said by", values: facets.speakers, selection: Binding(
                get: { Set(filters.speaker.map { [$0] } ?? []) },
                set: { filters.speaker = $0.first }
            ), allowsMany: false)
        }
        .help("Only transcript lines spoken by this person")
    }

    // MARK: - Type, improved, where

    private var typeChip: some View {
        Menu {
            Button("Any type") { filters.meetingType = nil }
            Divider()
            Button("1:1") { filters.meetingType = .oneOnOne }
            Button("Group") { filters.meetingType = .group }
        } label: {
            chip(filters.meetingType?.badgeLabel ?? "Any type", systemImage: "person.crop.circle", isActive: filters.meetingType != nil)
        }
        .chipMenu()
    }

    private var improvedChip: some View {
        Button { filters.improvedOnly.toggle() } label: {
            chip("Improved only", systemImage: "sparkles", isActive: filters.improvedOnly, chevron: false)
        }
        .buttonStyle(.plain)
        .help("Only meetings whose transcript was transcribed again from the recording")
        .accessibilityAddTraits(filters.improvedOnly ? .isSelected : [])
    }

    private static let kindOrder: [(SearchKind, String)] = [
        (.title, "Titles and people"), (.summary, "Summaries"), (.notes, "Notes"),
        (.template, "Write-ups"), (.transcript, "Transcripts"),
    ]

    private var kindsChip: some View {
        Menu {
            Button("Everywhere") { filters.kinds = [] }
            Divider()
            ForEach(Self.kindOrder, id: \.0) { kind, name in
                Toggle(name, isOn: membership(kind, in: $filters.kinds))
            }
        } label: {
            chip(kindsLabel, systemImage: "text.magnifyingglass", isActive: !filters.kinds.isEmpty)
        }
        .chipMenu()
        .help(filters.speaker != nil ? "“Said by” looks in transcripts only" : "Where to look for the words")
    }

    private var kindsLabel: String {
        let names = Self.kindOrder.filter { filters.kinds.contains($0.0) }.map(\.1)
        switch names.count {
        case 0: return "Everywhere"
        case 1: return "In \(names[0].lowercased())"
        default: return "In \(names.count) places"
        }
    }

    // MARK: - Helpers

    private func chip(_ text: String, systemImage: String, isActive: Bool, chevron: Bool = true) -> some View {
        Chip(text: text, systemImage: systemImage, tint: isActive ? .accentColor : nil, showsChevron: chevron)
    }

    private func summary(of values: Set<String>, empty: String) -> String {
        let sorted = values.sorted()
        guard let first = sorted.first else { return empty }
        return sorted.count == 1 ? first : "\(first) +\(sorted.count - 1)"
    }

    private func membership<T: Hashable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { if $0 { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } }
        )
    }
}

/// A searchable list of names with how many meetings each is in; ticks one or many.
private struct FacetPicker: View {
    let title: String
    let values: [SearchFacets.Value]
    @Binding var selection: Set<String>
    let allowsMany: Bool

    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [SearchFacets.Value] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? values : values.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }.buttonStyle(.borderless)
                }
            }
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
            if values.isEmpty {
                Text("No names yet. Attendees and renamed speakers show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Tokens.Space.s)
            } else {
                List(shown) { value in
                    Button { toggle(value.name) } label: {
                        HStack {
                            Image(systemName: selection.contains(value.name) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(value.name) ? Color.accentColor : .secondary)
                            Text(value.name).lineLimit(1)
                            Spacer()
                            Text("\(value.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(shown.count) * 28 + 8, 300))
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func toggle(_ name: String) {
        if selection.contains(name) {
            selection.remove(name)
        } else if allowsMany {
            selection.insert(name)
        } else {
            selection = [name]
            dismiss()
        }
    }
}

private extension View {
    /// A `Menu` whose label is a `Chip`, drawn as is.
    func chipMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
