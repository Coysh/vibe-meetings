import SwiftUI

// Summary templates: the page that lists and edits them, the picker behind a
// meeting's "+ Template" button, and the content of a template's tab.

// MARK: - A template's tab on a meeting

/// What a meeting's template tab shows: the write-up, progress while it's being
/// written, or a button to write it.
struct TemplateTabView: View {
    let template: SummaryTemplate?
    let text: String
    let isRunning: Bool
    /// Queued to be written automatically, after the meeting's summary.
    var isPending = false
    let progress: String
    let error: String?
    /// False until the meeting has a transcript to work from.
    let canGenerate: Bool
    let onGenerate: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        if isRunning {
            VStack(spacing: Tokens.Space.m) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: onCancel).controlSize(.small)
                }
                .readableWidth()
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.top, Tokens.Space.s)
                if text.isEmpty {
                    Spacer()
                } else {
                    SummaryView(markdown: text)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !text.isEmpty {
            VStack(spacing: 0) {
                if let error {
                    errorBanner(error)
                        .readableWidth()
                        .padding(.horizontal, Tokens.Space.xl)
                        .padding(.top, Tokens.Space.s)
                }
                SummaryView(markdown: text)
            }
        } else if isPending {
            pendingState
        } else {
            emptyState
        }
    }

    private var pendingState: some View {
        VStack(spacing: Tokens.Space.m) {
            Spacer()
            Text(template?.emoji ?? "📄").font(.system(size: 44))
            Text(template?.name ?? "This template was deleted")
                .font(Tokens.detailTitle)
            Label("This will be written after the summary.", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Remove this tab", action: onRemove)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.Space.m) {
            Spacer()
            Text(template?.emoji ?? "📄").font(.system(size: 44))
            Text(template?.name ?? "This template was deleted")
                .font(Tokens.detailTitle)
            if let error { errorBanner(error) }
            if template != nil {
                Button(action: onGenerate) {
                    Label("Write it up", systemImage: "sparkles")
                }
                .buttonStyle(.capsule(.primary))
                .disabled(!canGenerate)
                if !canGenerate {
                    Text("Record or import a transcript first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Remove this tab", action: onRemove)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Label("Couldn't write it up: \(message)", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - "+ Template" picker

/// The popover behind a meeting's "+ Template": favourites first, then every
/// template by category, with a star to favourite and a search field.
struct TemplatePickerView: View {
    /// Templates already open on this meeting.
    let openIDs: Set<String>
    let onPick: (SummaryTemplate) -> Void
    let onManage: () -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""

    private var store: SummaryTemplateStore { env.summaryTemplates }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func matches(_ template: SummaryTemplate) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || template.name.lowercased().contains(q) || template.category.lowercased().contains(q)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search templates…", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search templates")
            }
            .padding(10)
            .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous).strokeBorder(Tokens.stroke))
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let favorites = store.favorites.filter(matches)
                    if !favorites.isEmpty {
                        header("Favorite Templates")
                        ForEach(favorites) { row($0) }
                    }
                    ForEach(store.categories, id: \.self) { category in
                        let items = store.templates(in: category).filter { !store.isFavorite($0) && matches($0) }
                        if !items.isEmpty {
                            header(category)
                            ForEach(items) { row($0) }
                        }
                    }
                    if isSearching, store.all.filter(matches).isEmpty {
                        Text("No templates match “\(query)”.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider()
            Button(action: onManage) {
                Label("Manage templates…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(width: 340, height: 440)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Tokens.sectionTitle)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func row(_ template: SummaryTemplate) -> some View {
        HStack(spacing: 10) {
            Text(template.emoji).frame(width: 24)
            Text(template.name).lineLimit(1)
            Spacer(minLength: 8)
            if openIDs.contains(template.id) {
                Image(systemName: "checkmark").foregroundStyle(.secondary).help("Already on this meeting")
            }
            Button {
                store.toggleFavorite(template)
            } label: {
                Image(systemName: store.isFavorite(template) ? "star.fill" : "star")
                    .foregroundStyle(store.isFavorite(template) ? Color.yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(store.isFavorite(template) ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(store.isFavorite(template) ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { onPick(template) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - The Templates page

/// Every template: starred ones first, then by category. Built-ins can be read
/// and duplicated; your own can be edited and deleted.
struct TemplatesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editing: SummaryTemplate?
    @State private var pendingDelete: SummaryTemplate?
    @State private var editingSummaryPrompt = false
    @State private var query = ""

    private var store: SummaryTemplateStore { env.summaryTemplates }

    private func matches(_ template: SummaryTemplate) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || template.name.lowercased().contains(q)
            || template.category.lowercased().contains(q) || template.instructions.lowercased().contains(q)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.xl) {
                PageHeader(
                    title: "Templates",
                    subtitle: "Ways to write up a meeting. Add one to any meeting with + Template. "
                        + "Default ones are written after every recording, once the summary is done."
                ) {
                    Button {
                        editing = SummaryTemplate(
                            id: "custom-" + UUID().uuidString,
                            name: "", emoji: "📝",
                            category: SummaryTemplate.customCategory,
                            instructions: ""
                        )
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                    .buttonStyle(.capsule(.primary))
                }

                // The prompt every meeting's summary is written with. Always here, whatever's searched for.
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    SectionHeader(title: "Summary")
                    summaryRow
                }

                searchField

                let favorites = store.favorites.filter(matches)
                if !favorites.isEmpty {
                    group("Favorites", templates: favorites)
                }
                ForEach(store.categories, id: \.self) { category in
                    let items = store.templates(in: category).filter { !store.isFavorite($0) && matches($0) }
                    if !items.isEmpty {
                        group(category, templates: items)
                    }
                }
            }
            .padding(.top, Tokens.Space.xl)
            .padding(.bottom, Tokens.Space.xxl)
            .readableWidth()
            .padding(.horizontal, Tokens.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface)
        .floatingActionBar()
        .sheet(item: $editing) { template in
            TemplateEditorSheet(template: template)
        }
        .sheet(isPresented: $editingSummaryPrompt) {
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                Text("Summary prompt").font(.headline)
                Text("The full instructions every summary is written with. The transcript, who was speaking and your notes are added for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SummaryPromptEditor(onClose: { editingSummaryPrompt = false })
            }
            .padding()
            .frame(width: 640, height: 580)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { template in
            Button("Delete Template", role: .destructive) { store.delete(template) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Write-ups already made from it stay on their meetings.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search templates…", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search templates")
        }
        .padding(10)
        .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous).strokeBorder(Tokens.stroke))
    }

    /// The summary's own prompt, in the same style as a template's row.
    private var summaryRow: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: "text.document")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Summary").font(Tokens.rowTitle).lineLimit(1)
                    if env.summaryPromptIsCustomised {
                        Badge(text: "Customised", color: .orange)
                    } else {
                        Badge(text: "Built-in")
                    }
                }
                Text("Written for every meeting. Click to edit the full prompt.")
                    .font(Tokens.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.m)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { editingSummaryPrompt = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func group(_ title: String, templates: [SummaryTemplate]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionHeader(title: title)
            ForEach(templates) { template in
                row(template)
            }
        }
    }

    private func row(_ template: SummaryTemplate) -> some View {
        HStack(spacing: Tokens.Space.m) {
            Text(template.emoji).font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.name).font(Tokens.rowTitle).lineLimit(1)
                    if template.isBuiltIn { Badge(text: "Built-in") }
                    if store.isDefault(template) { Badge(text: "Default", color: .accentColor) }
                }
                Text(preview(template))
                    .font(Tokens.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Space.m)
            Button {
                store.toggleFavorite(template)
            } label: {
                Image(systemName: store.isFavorite(template) ? "star.fill" : "star")
                    .foregroundStyle(store.isFavorite(template) ? Color.yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(store.isFavorite(template) ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(store.isFavorite(template) ? "Remove from favorites" : "Add to favorites")

            Menu {
                Button(template.isBuiltIn ? "View…" : "Edit…") { editing = template }
                Button(store.isDefault(template) ? "Remove Default" : "Make Default") { store.toggleDefault(template) }
                Button("Duplicate") { editing = store.duplicate(template) }
                if !template.isBuiltIn {
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = template }
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 22, height: 22)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { editing = template }
        .accessibilityElement(children: .contain)
    }

    /// The first line of what the template asks for.
    private func preview(_ template: SummaryTemplate) -> String {
        template.instructions
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? "No instructions yet"
    }
}

// MARK: - Editor

/// Create or edit a template. Built-in ones are read-only; "Duplicate" makes a copy to change.
struct TemplateEditorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SummaryTemplate
    /// A change to "Default" on a template that isn't saved yet; applied on Save, so cancelling leaves nothing behind.
    @State private var pendingDefault: Bool?

    init(template: SummaryTemplate) {
        _draft = State(initialValue: template)
    }

    private var isDefault: Binding<Bool> {
        Binding(
            get: { pendingDefault ?? env.summaryTemplates.isDefault(draft) },
            set: { isOn in
                // A built-in can't be saved, so it takes effect straight away.
                if readOnly { env.summaryTemplates.setDefault(draft, isOn) } else { pendingDefault = isOn }
            }
        )
    }

    private var readOnly: Bool { draft.isBuiltIn }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text(readOnly ? draft.name : (draft.name.isEmpty ? "New Template" : "Edit Template"))
                .font(.headline)

            HStack(spacing: Tokens.Space.s) {
                TextField("📝", text: $draft.emoji)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 52)
                    .onChange(of: draft.emoji) { _, new in
                        if new.count > 1, let first = new.first { draft.emoji = String(first) }
                    }
                    .accessibilityLabel("Emoji")
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(readOnly)

            TextField("Category", text: $draft.category)
                .textFieldStyle(.roundedBorder)
                .disabled(readOnly)

            Text("Instructions").font(Tokens.sectionTitle).foregroundStyle(.secondary)
            TextEditor(text: $draft.instructions)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous).strokeBorder(Tokens.stroke))
                .frame(minHeight: 240)
                .disabled(readOnly)

            Text(readOnly
                 ? "Built-in templates can't be changed. Duplicate it to make your own version."
                 : "Say what to write and how to lay it out. The transcript, who was speaking and your notes are added for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Default: write this after every recording", isOn: isDefault)
                .help("Once a new meeting's summary is written, this one is written too")

            HStack {
                if readOnly {
                    Button("Duplicate to Edit") {
                        _ = env.summaryTemplates.duplicate(draft)
                        dismiss()
                    }
                }
                Spacer()
                Button(readOnly ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !readOnly {
                    Button("Save") {
                        draft.category = draft.category.trimmingCharacters(in: .whitespaces).isEmpty
                            ? SummaryTemplate.customCategory : draft.category
                        draft.emoji = draft.emoji.isEmpty ? "📝" : draft.emoji
                        env.summaryTemplates.save(draft)
                        if let pendingDefault { env.summaryTemplates.setDefault(draft, pendingDefault) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.capsule(.primary))
                    .disabled(!canSave)
                }
            }
        }
        .padding()
        .frame(width: 480)
    }
}

// MARK: - Summary prompt

/// Edits the prompt every summary is written with. Used on the Templates page and in Settings, and both
/// work on the same saved value, so a change made in one shows up in the other.
struct SummaryPromptEditor: View {
    @Environment(AppEnvironment.self) private var env
    /// Set when shown in a sheet: adds a Cancel button and closes after saving.
    var onClose: (() -> Void)?

    @State private var draft = ""
    /// What the editor last showed as saved, to tell the user's typing from a change made elsewhere.
    @State private var baseline = ""
    @State private var showingDefault = false

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft != env.effectiveSummaryPrompt
    }

    private var canReset: Bool {
        env.summaryPromptIsCustomised || !AppEnvironment.isDefaultSummaryPrompt(draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            status

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous).strokeBorder(Tokens.stroke))
                .frame(minHeight: 280)
                .accessibilityLabel("Summary prompt")

            if showingDefault {
                GroupBox("Built-in summary prompt") {
                    ScrollView {
                        Text(AppEnvironment.defaultSummaryPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }

            HStack {
                Button("Reset to Default") {
                    env.setSummaryPrompt("")
                    sync()
                }
                .disabled(!canReset)
                Button(showingDefault ? "Hide Default" : "Show Default") { showingDefault.toggle() }
                Spacer()
                if let onClose {
                    Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                }
                Button("Save") {
                    env.setSummaryPrompt(draft)
                    sync()
                    onClose?()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.capsule(.primary))
                .disabled(!canSave)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: env.customSystemPrompt) {
            // Changed from somewhere else (the other screen): follow it, unless there's unsaved typing here.
            if draft == baseline { draft = env.effectiveSummaryPrompt }
            baseline = env.effectiveSummaryPrompt
        }
    }

    @ViewBuilder
    private var status: some View {
        if env.summaryPromptIsCustomised {
            VStack(alignment: .leading, spacing: 2) {
                Label("Customised — differs from the current default", systemImage: "pencil.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Text("Improvements to the built-in prompt won't reach a customised one. Reset to Default to pick them up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Label("Using the built-in prompt", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func sync() {
        draft = env.effectiveSummaryPrompt
        baseline = draft
    }
}
