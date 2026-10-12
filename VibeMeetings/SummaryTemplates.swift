import Foundation
import Observation

/// A reusable way to write up a meeting: "Customer: Discovery", "Pipeline Review",
/// your own. Each one an extra output next to the meeting's main summary.
struct SummaryTemplate: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var emoji: String
    var category: String
    /// What to write, in the user's (or built-in) words. The transcript conventions
    /// are added in front of this — see `systemPrompt`.
    var instructions: String
    var isBuiltIn: Bool = false

    /// The full system prompt: how to read the transcript, then what to produce.
    var systemPrompt: String {
        Self.preamble + "\n\n" + instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same grounding the main summary prompt gives (who "You" and "Others" are, no invention).
    static let preamble = """
    You are a meeting-notes assistant. The transcript below was produced by a local \
    speech-to-text model on a 2-channel recording. Speaker "You" was on the user's \
    microphone. Everyone else was on system audio: they appear either as "Others" \
    (all remote participants together) or as individual speakers — "Speaker 1", \
    "Speaker 2" … or names the user has given them. The "Speakers:" line lists them. \
    Treat the speaker labels as ground truth for who said what. Do not invent speakers, \
    and do not guess which attendee a numbered "Speaker N" is.

    Only use facts present in the transcript (and the user's own notes, if provided; \
    they may clarify or correct what was transcribed). If something wasn't said, write \
    "unspecified" rather than guessing. Do not include a preamble, apologies, or a \
    restatement of these instructions. Output Markdown only, with no code fence around \
    the whole document.
    """

    static let customCategory = "My Templates"
}

extension SummaryTemplate {
    /// Ships with the app. Read-only; "Duplicate" makes an editable copy.
    static let builtIns: [SummaryTemplate] = [
        SummaryTemplate(
            id: "action-items", name: "Action Items & Decisions", emoji: "✅", category: "General",
            instructions: """
            Produce Markdown with these sections, omitting any that are empty:
            ## Decisions
            Terse bullets — only things explicitly decided.
            ## Action items
            Checkbox bullets: `- [ ] **<assignee>** — <action>. _Due: <when or "unspecified">._` \
            Every action item needs one clear assignee. If it can't be determined, assign it to **You**.
            ## Open questions
            Bullets.
            """, isBuiltIn: true),
        SummaryTemplate(
            id: "key-points", name: "Key Points", emoji: "🔑", category: "General",
            instructions: """
            Write the main points of the meeting as short bullets grouped under a few clear \
            `##` topic headings, in the order the topics came up. One line per bullet. Put \
            who said it only when it matters. Finish with a one-sentence `## Bottom line`.
            """, isBuiltIn: true),
        SummaryTemplate(
            id: "follow-up-email", name: "Follow-up Email", emoji: "✉️", category: "General",
            instructions: """
            Draft a follow-up email to the other people in the meeting, from the user. Give a \
            `Subject:` line, then a short, warm, plain-spoken body: thanks, a recap of what was \
            decided, the action items with their owners, and the agreed next step. No filler and \
            no promises that weren't made in the meeting.
            """, isBuiltIn: true),
        SummaryTemplate(
            id: "lecture-notes", name: "Lecture & Webinar Notes", emoji: "🎓", category: "General",
            instructions: """
            Write structured study notes: a `##` heading per topic, bullets underneath, key terms \
            in bold with a short definition where one was given, and a final `## Takeaways` list \
            of the five most important points.
            """, isBuiltIn: true),

        SummaryTemplate(
            id: "customer-discovery", name: "Customer: Discovery", emoji: "🔎", category: "Commercial",
            instructions: """
            Write up this discovery call with these sections, omitting any that weren't covered:
            ## Company & context
            ## Pain points
            In the customer's own words where possible.
            ## Current solution & alternatives
            ## Goals & success criteria
            ## Budget, authority & timeline
            ## Objections & risks
            ## Next steps
            Checkbox bullets with an owner.
            """, isBuiltIn: true),
        SummaryTemplate(
            id: "pipeline-review", name: "Pipeline Review", emoji: "📈", category: "Commercial",
            instructions: """
            For each deal discussed, give a `###` heading with the deal name, then bullets for: \
            stage, value (if stated), where it stands, risks, and the next step with its owner. \
            Finish with `## Forecast risks` and `## Asks` (what people need from others).
            """, isBuiltIn: true),
        SummaryTemplate(
            id: "customer-existing", name: "Customer: Existing", emoji: "❤️", category: "Commercial",
            instructions: """
            Write up this call with an existing customer:
            ## How things are going
            ## Feedback & feature requests
            ## Problems raised
            ## Expansion opportunities
            ## Renewal or churn signals
            ## Next steps
            Checkbox bullets with an owner. Omit sections that weren't covered.
            """, isBuiltIn: true),

        SummaryTemplate(
            id: "one-on-one", name: "1:1", emoji: "🤝", category: "Leadership",
            instructions: """
            Write up this one-to-one:
            ## Topics discussed
            ## Wins
            ## Feedback given and received
            ## Blockers & support needed
            ## Commitments
            Checkbox bullets with an owner.
            ## For the next 1:1
            Omit sections that weren't covered.
            """, isBuiltIn: true),
        SummaryTemplate(
            id: "board-meeting", name: "Board Meeting", emoji: "🎩", category: "Leadership",
            instructions: """
            Write minutes: a `##` heading per agenda item with a short summary of the discussion, \
            then `## Resolutions` (what was decided, and who proposed or approved it if stated), \
            `## Metrics mentioned`, `## Risks raised`, and `## Actions` as checkbox bullets with an owner.
            """, isBuiltIn: true),

        SummaryTemplate(
            id: "standup", name: "Daily Standup", emoji: "🌅", category: "Product & Engineering",
            instructions: """
            One `###` heading per person who spoke, with three bullets: **Yesterday**, **Today**, \
            **Blockers** (write "none" if they said none). End with `## Blockers to unblock`, \
            listing each blocker with who can help.
            """, isBuiltIn: true),
        SummaryTemplate(
            id: "technical-discussion", name: "Technical Discussion", emoji: "🏗️", category: "Product & Engineering",
            instructions: """
            ## Problem
            ## Options considered
            For each option: a bullet with its pros and cons as stated.
            ## Decision & rationale
            ## Open questions
            ## Action items
            Checkbox bullets with an owner.
            """, isBuiltIn: true),
        SummaryTemplate(
            id: "retrospective", name: "Retrospective", emoji: "🔁", category: "Product & Engineering",
            instructions: """
            ## What went well
            ## What didn't
            ## Ideas to try
            ## Actions
            Checkbox bullets with an owner. Group similar points together.
            """, isBuiltIn: true),

        SummaryTemplate(
            id: "interview", name: "Interview", emoji: "🧑‍💼", category: "People",
            instructions: """
            Summarise the interview: ## Background, ## Strengths shown, ## Concerns or gaps, \
            ## Notable answers (short quotes), and ## Topics covered with a line on what the \
            candidate said about each. Describe what was said; do not give a hire / no-hire verdict.
            """, isBuiltIn: true),
    ]

    /// Shown first in the picker until the user stars their own.
    static let defaultFavoriteIDs: Set<String> = ["action-items", "customer-discovery", "pipeline-review", "follow-up-email"]
}

/// The built-in templates, the user's own, which ones are starred, and which are written after every recording.
@Observable
@MainActor
final class SummaryTemplateStore {
    private static let customKey = "VibeMeetings.SummaryTemplates.Custom"
    private static let favoritesKey = "VibeMeetings.SummaryTemplates.Favorites"
    private static let defaultsKey = "VibeMeetings.SummaryTemplates.Defaults"

    private(set) var customTemplates: [SummaryTemplate]
    private(set) var favoriteIDs: Set<String>
    /// Ids of the templates written after every recording. Empty until the user picks some.
    private(set) var defaultIDs: Set<String>

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.customKey),
           let saved = try? JSONDecoder().decode([SummaryTemplate].self, from: data) {
            customTemplates = saved
        } else {
            customTemplates = []
        }
        if let saved = defaults.array(forKey: Self.favoritesKey) as? [String] {
            favoriteIDs = Set(saved)
        } else {
            favoriteIDs = SummaryTemplate.defaultFavoriteIDs
        }
        defaultIDs = Set(defaults.array(forKey: Self.defaultsKey) as? [String] ?? [])
    }

    var all: [SummaryTemplate] { SummaryTemplate.builtIns + customTemplates }

    func template(id: String) -> SummaryTemplate? {
        all.first { $0.id == id }
    }

    var favorites: [SummaryTemplate] {
        all.filter { favoriteIDs.contains($0.id) }
    }

    /// Written after every recording, once its summary is done, in list order. Looked up by id, so one
    /// that has since been deleted is simply skipped.
    var defaultTemplates: [SummaryTemplate] {
        all.filter { defaultIDs.contains($0.id) }
    }

    /// Category names in a stable order: built-in categories first, the user's last.
    var categories: [String] {
        var seen = Set<String>()
        return all.map(\.category).filter { seen.insert($0).inserted }
    }

    func templates(in category: String) -> [SummaryTemplate] {
        all.filter { $0.category == category }
    }

    func isFavorite(_ template: SummaryTemplate) -> Bool {
        favoriteIDs.contains(template.id)
    }

    func toggleFavorite(_ template: SummaryTemplate) {
        if favoriteIDs.contains(template.id) {
            favoriteIDs.remove(template.id)
        } else {
            favoriteIDs.insert(template.id)
        }
        UserDefaults.standard.set(Array(favoriteIDs).sorted(), forKey: Self.favoritesKey)
    }

    func isDefault(_ template: SummaryTemplate) -> Bool {
        defaultIDs.contains(template.id)
    }

    func setDefault(_ template: SummaryTemplate, _ isOn: Bool) {
        if isOn { defaultIDs.insert(template.id) } else { defaultIDs.remove(template.id) }
        persistDefaults()
    }

    func toggleDefault(_ template: SummaryTemplate) {
        setDefault(template, !isDefault(template))
    }

    /// Add a new custom template, or replace the one with the same id.
    func save(_ template: SummaryTemplate) {
        var template = template
        template.isBuiltIn = false
        if let index = customTemplates.firstIndex(where: { $0.id == template.id }) {
            customTemplates[index] = template
        } else {
            customTemplates.append(template)
        }
        persistCustom()
    }

    func delete(_ template: SummaryTemplate) {
        customTemplates.removeAll { $0.id == template.id }
        favoriteIDs.remove(template.id)
        defaultIDs.remove(template.id)
        persistCustom()
        UserDefaults.standard.set(Array(favoriteIDs).sorted(), forKey: Self.favoritesKey)
        persistDefaults()
    }

    /// An editable copy (of a built-in or a custom template) in "My Templates".
    func duplicate(_ template: SummaryTemplate) -> SummaryTemplate {
        let copy = SummaryTemplate(
            id: "custom-" + UUID().uuidString,
            name: template.name + " Copy",
            emoji: template.emoji,
            category: SummaryTemplate.customCategory,
            instructions: template.instructions
        )
        save(copy)
        return copy
    }

    private func persistDefaults() {
        UserDefaults.standard.set(Array(defaultIDs).sorted(), forKey: Self.defaultsKey)
    }

    private func persistCustom() {
        if let data = try? JSONEncoder().encode(customTemplates) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
    }
}
