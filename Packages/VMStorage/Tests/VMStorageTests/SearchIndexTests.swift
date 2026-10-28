import XCTest
import VMCore
@testable import VMStorage

/// Runs against a synthetic library in a temp directory — never the real one.
final class SearchIndexTests: XCTestCase {
    private var root: URL!
    private var dbURL: URL!
    private var index: SearchIndex!

    private let budgetID = UUID()
    private let standupID = UUID()
    private let oneOnOneID = UUID()
    private let importedID = UUID()

    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vmsearch-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("library")
        dbURL = tmp.appendingPathComponent("index.sqlite")
        let cal = Calendar.current
        let oct27 = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14))!
        let oct20 = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))!
        let aug3 = cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))!
        let jan5 = cal.date(from: DateComponents(year: 2025, month: 1, day: 5, hour: 9))!

        var budget = makeMeeting(id: budgetID, title: "Budget review", start: oct27)
        budget.attendees = ["Priya Shah", "Sam Lee"]
        budget.org = "Acme"
        budget.labels = ["finance"]
        budget.participants = [.you, Speaker(id: "others", displayName: "Priya Shah", channel: .system)]
        try write(budget, folder: "Clients/Acme/Budget review", segments: [
            seg("you", 0, "Thanks for joining."),
            seg("others", 10, "The marketing budget is over by ten percent."),
            seg("you", 20, "We signed off the quarterly forecast last week."),
            seg("others", 30, "Conference spend should be cut."),
        ], summary: "## Summary\nMarketing budget overspent. Forecast to be updated.", notes: "Ask about travel costs")
        try write(template: "actions", "- Update the forecast", folder: "Clients/Acme/Budget review")
        try "{}".write(to: root.appendingPathComponent("Clients/Acme/Budget review/refined.json"), atomically: true, encoding: .utf8)

        try write(makeMeeting(id: standupID, title: "Team standup", start: oct20), folder: "Internal/Team standup", segments: [
            seg("you", 0, "Quick round of updates."),
            seg("others", 5, "Nothing blocking, the forecast is fine."),
        ])

        var oneOnOne = makeMeeting(id: oneOnOneID, title: "1:1 Sam", start: aug3)
        oneOnOne.attendees = ["Sam Lee"]
        try write(oneOnOne, folder: "Clients/Acme/Sub/1-1 Sam", segments: [
            seg("others", 0, "I need to sign the contract."),
        ], summary: "Contract signature pending.")

        var imported = makeMeeting(id: importedID, title: "Old import", start: jan5)
        imported.participants = [.imported]
        try write(imported, folder: "Old import", segments: nil,
                  transcriptMarkdown: "# Old import\n\n## Full transcript\n> [!note]- Expand transcript\n>\n> **Imported** [00:00]\n> We talked about the garden shed.\n")

        index = SearchIndex(databaseURL: dbURL)
        try await index.sync(tree: tree(), root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - Matching

    func testStemmingFindsInflections() throws {
        // "signing" → "sign": matches "signed" (budget) and "sign" (1:1).
        let ids = try search("signing").hits.map(\.meetingID)
        XCTAssertEqual(Set(ids), [budgetID, oneOnOneID])
    }

    func testPhraseVersusLooseTerms() throws {
        XCTAssertEqual(Set(try search("budget marketing").hits.map(\.meetingID)), [budgetID])
        XCTAssertTrue(try search("\"budget marketing\"").hits.isEmpty)
        XCTAssertEqual(try search("\"marketing budget\"").hits.map(\.meetingID), [budgetID])
    }

    func testLastTermMatchesAsPrefix() throws {
        // "quarter" is a prefix of "quarterly" (stemmed "quarterli"), not the same word.
        XCTAssertEqual(try search("quarter").hits.map(\.meetingID), [budgetID])
        XCTAssertTrue(try search("\"quarter\"").hits.isEmpty)
        // Only the last word is a prefix.
        XCTAssertTrue(try search("quarter marketing").hits.isEmpty)
        XCTAssertEqual(try search("marketing quarter").hits.map(\.meetingID), [budgetID])
    }

    func testExclusion() throws {
        XCTAssertEqual(Set(try search("forecast").hits.map(\.meetingID)), [budgetID, standupID])
        XCTAssertEqual(try search("forecast -blocking").hits.map(\.meetingID), [budgetID])
    }

    func testSyntaxInInputIsJustText() throws {
        for text in ["\"", "budget\"", "*", "(budget", "NEAR(a b)", "body: budget", "a AND OR NOT", "-", "-- --", "\"unterminated phrase"] {
            XCTAssertNoThrow(try search(text), text)
        }
        XCTAssertEqual(try search("(budget").hits.map(\.meetingID), [budgetID])
    }

    func testImportedMarkdownTranscriptIsIndexed() throws {
        let hit = try XCTUnwrap(try search("shed").hits.first)
        XCTAssertEqual(hit.meetingID, importedID)
        XCTAssertEqual(hit.snippets.first?.kind, .transcript)
        XCTAssertNil(hit.snippets.first?.start)
    }

    // MARK: - Snippets and ranking

    func testSnippetsHighlightAndCarryTranscriptPosition() throws {
        let hit = try XCTUnwrap(try search("conference").hits.first)
        let line = try XCTUnwrap(hit.snippets.first { $0.kind == .transcript })
        XCTAssertTrue(line.text.contains("\u{E000}Conference\u{E001}"))
        XCTAssertEqual(line.speaker, "Priya Shah")
        XCTAssertEqual(line.start, 30)
        XCTAssertNotNil(line.segmentID)
    }

    func testSnippetsAreCappedAtThreeWithDocumentFirst() throws {
        let hit = try XCTUnwrap(try search("the").hits.first { $0.meetingID == budgetID })
        XCTAssertLessThanOrEqual(hit.snippets.count, 3)
        let budget = try XCTUnwrap(try search("forecast").hits.first { $0.meetingID == budgetID })
        XCTAssertNotEqual(budget.snippets.first?.kind, .transcript)
        let starts = budget.snippets.compactMap(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    func testTitleOutranksPassingMention() throws {
        XCTAssertEqual(try index.searchSync(SearchQuery(text: "standup"), now: now).hits.first?.meetingID, standupID)
        XCTAssertEqual(try index.searchSync(SearchQuery(text: "forecast", sort: .newest), now: now).hits.map(\.meetingID), [budgetID, standupID])
    }

    // MARK: - Filters

    func testDateFilters() throws {
        XCTAssertEqual(Set(try search("forecast", { $0.dateRange = .pastWeek }).hits.map(\.meetingID)), [budgetID])
        XCTAssertEqual(Set(try search("forecast", { $0.dateRange = .pastMonth }).hits.map(\.meetingID)), [budgetID, standupID])
        let aug = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 3))!
        XCTAssertEqual(try search("sign", { $0.dateRange = .custom(from: aug, to: aug) }).hits.map(\.meetingID), [oneOnOneID])
    }

    func testFolderFilterIncludesSubfolders() throws {
        XCTAssertEqual(Set(try search("sign", { $0.folderPath = "Clients/Acme" }).hits.map(\.meetingID)), [budgetID, oneOnOneID])
        XCTAssertEqual(try search("sign", { $0.folderPath = "Clients/Acme/Sub" }).hits.map(\.meetingID), [oneOnOneID])
        // A sibling whose name starts the same isn't a subfolder.
        XCTAssertTrue(try search("sign", { $0.folderPath = "Clients/Ac" }).hits.isEmpty)
    }

    func testPeopleOrgTypeLabelsImproved() throws {
        XCTAssertEqual(Set(try search("sign", { $0.people = ["sam lee"] }).hits.map(\.meetingID)), [budgetID, oneOnOneID])
        XCTAssertEqual(try search("forecast", { $0.people = ["Priya Shah"] }).hits.map(\.meetingID), [budgetID])
        XCTAssertEqual(try search("forecast", { $0.org = "acme" }).hits.map(\.meetingID), [budgetID])
        XCTAssertEqual(try search("sign", { $0.meetingType = .oneOnOne }).hits.map(\.meetingID), [oneOnOneID])
        XCTAssertEqual(try search("forecast", { $0.labels = ["finance"] }).hits.map(\.meetingID), [budgetID])
        XCTAssertEqual(try search("forecast", { $0.improvedOnly = true }).hits.map(\.meetingID), [budgetID])
    }

    func testKindsAndSpeaker() throws {
        // "travel" is only in the notes.
        XCTAssertEqual(try search("travel", { $0.kinds = [.notes] }).hits.map(\.meetingID), [budgetID])
        XCTAssertTrue(try search("travel", { $0.kinds = [.transcript, .summary] }).hits.isEmpty)
        XCTAssertEqual(try search("Acme", { $0.kinds = [.title] }).hits.map(\.meetingID), [budgetID])
        XCTAssertEqual(try search("update", { $0.kinds = [.template] }).hits.first?.snippets.first?.label, "actions")
        // "forecast": You said it in the budget meeting; Others said it in the standup.
        XCTAssertEqual(try search("forecast", { $0.speaker = "You" }).hits.map(\.meetingID), [budgetID])
        XCTAssertEqual(try search("forecast", { $0.speaker = "Others" }).hits.map(\.meetingID), [standupID])
    }

    func testBrowseModeListsFilteredMeetingsNewestFirst() throws {
        let r = try search("", { $0.folderPath = "Clients" })
        XCTAssertTrue(r.isBrowse)
        XCTAssertEqual(r.hits.map(\.meetingID), [budgetID, oneOnOneID])
        XCTAssertEqual(try search("", { $0.speaker = "Priya Shah" }).hits.map(\.meetingID), [budgetID])
        XCTAssertTrue(try search("").hits.isEmpty)
    }

    func testFacets() async throws {
        let f = try await index.facets()
        XCTAssertEqual(f.meetingCount, 4)
        XCTAssertEqual(f.people.first, SearchFacets.Value(name: "Sam Lee", count: 2))
        XCTAssertTrue(f.people.contains { $0.name == "Priya Shah" })
        XCTAssertFalse(f.people.contains { $0.name == "You" || $0.name == "Others" })
        XCTAssertTrue(f.speakers.contains { $0.name == "You" })
        XCTAssertEqual(f.orgs.map(\.name), ["Acme"])
        XCTAssertEqual(f.labels.map(\.name), ["finance"])
    }

    // MARK: - Incremental sync

    func testSyncReindexesOnlyChangedMeetings() async throws {
        let again = try await index.sync(tree: tree(), root: root)
        XCTAssertEqual(again, SearchIndex.SyncStats(indexed: 0, removed: 0, total: 4))

        let summary = root.appendingPathComponent("Internal/Team standup/summary.md")
        try "Decided to adopt the zebra roadmap.".write(to: summary, atomically: true, encoding: .utf8)
        let stats = try await index.sync(tree: tree(), root: root)
        XCTAssertEqual(stats.indexed, 1)
        XCTAssertEqual(try search("zebra").hits.map(\.meetingID), [standupID])
    }

    func testDeletedMeetingIsRemoved() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("Internal"))
        let stats = try await index.sync(tree: tree(), root: root)
        XCTAssertEqual(stats.removed, 1)
        XCTAssertEqual(try search("forecast").hits.map(\.meetingID), [budgetID])
    }

    func testRenamedSpeakerAndRefinementAreReindexed() async throws {
        let url = root.appendingPathComponent("Internal/Team standup/meeting.json")
        var standup = try XCTUnwrap(FolderTreeScanner.scan(root: root).meetingNode(id: standupID)?.meeting)
        standup.participants = [.you, Speaker(id: "others", displayName: "Jordan Park", channel: .system)]
        try FolderTreeScanner.writeMeeting(standup, to: url)
        try "{}".write(to: root.appendingPathComponent("Internal/Team standup/refined.json"), atomically: true, encoding: .utf8)
        try await index.sync(tree: tree(), root: root)

        XCTAssertEqual(try search("forecast", { $0.speaker = "Jordan Park" }).hits.map(\.meetingID), [standupID])
        XCTAssertEqual(Set(try search("forecast", { $0.improvedOnly = true }).hits.map(\.meetingID)), [budgetID, standupID])
    }

    func testMovedMeetingUpdatesFolder() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Internal/Team standup"),
                                         to: root.appendingPathComponent("Archive/Team standup"))
        try await index.sync(tree: tree(), root: root)
        XCTAssertEqual(try search("blocking", { $0.folderPath = "Archive" }).hits.map(\.meetingID), [standupID])
    }

    func testNewRootRebuilds() async throws {
        let other = root.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let stats = try await index.sync(tree: FolderTreeScanner.scan(root: other), root: other)
        XCTAssertEqual(stats.total, 0)
        XCTAssertTrue(try search("forecast").hits.isEmpty)
        // Back to the first root: everything is indexed again.
        let back = try await index.sync(tree: tree(), root: root)
        XCTAssertEqual(back.indexed, 4)
    }

    func testSurvivesReopenAndSchemaChange() async throws {
        index = SearchIndex(databaseURL: dbURL)
        let stats = try await index.sync(tree: tree(), root: root)
        XCTAssertEqual(stats.indexed, 0)
        XCTAssertEqual(try search("marketing").hits.map(\.meetingID), [budgetID])
    }

    // MARK: - Query builder

    func testTerms() {
        XCTAssertNil(SearchQuery.terms(for: "   "))
        XCTAssertNil(SearchQuery.terms(for: "-only -negatives"))
        XCTAssertEqual(SearchQuery.terms(for: "budget sign"), .init(positives: ["\"budget\"", "\"sign\"*"], negatives: []))
        XCTAssertEqual(SearchQuery.terms(for: "\"sign off\" budget -travel"),
                       .init(positives: ["\"sign off\"", "\"budget\"*"], negatives: ["\"travel\""]))
        XCTAssertEqual(SearchQuery.terms(for: "a\"b"), .init(positives: ["\"a\"\"b\"*"], negatives: []))
        XCTAssertEqual(SearchQuery.terms(for: "x"), .init(positives: ["\"x\""], negatives: []))
    }

    func testWordsMayBeInDifferentPartsOfAMeeting() throws {
        // "Priya" is an attendee (title row); "conference" is only in the transcript.
        XCTAssertEqual(try search("priya conference").hits.map(\.meetingID), [budgetID])
        XCTAssertTrue(try search("priya blocking").hits.isEmpty)
    }

    // MARK: - Helpers

    private func search(_ text: String, _ filters: (inout SearchFilters) -> Void = { _ in }) throws -> SearchResults {
        var f = SearchFilters()
        filters(&f)
        return try index.searchSync(SearchQuery(text: text, filters: f), now: now)
    }

    private func tree() -> FolderNode { FolderTreeScanner.scan(root: root) }

    private func makeMeeting(id: UUID, title: String, start: Date) -> Meeting {
        Meeting(id: id, title: title, startedAt: start, endedAt: start.addingTimeInterval(1800),
                folderRelativePath: "", transcriptionEngine: EngineRef(kind: "test", version: "1"), modelId: "test")
    }

    private func seg(_ speaker: String, _ start: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerId: speaker, channel: speaker == "you" ? .mic : .system, start: start, end: start + 2, text: text)
    }

    private func write(_ meeting: Meeting, folder: String, segments: [TranscriptSegment]?,
                       summary: String? = nil, notes: String? = nil, transcriptMarkdown: String? = nil) throws {
        let mf = MeetingFolder(url: root.appendingPathComponent(folder))
        try FileManager.default.createDirectory(at: mf.url, withIntermediateDirectories: true)
        try FolderTreeScanner.writeMeeting(meeting, to: mf.metadataURL)
        if let segments { try SegmentsFile.save(segments, to: mf.segmentsURL) }
        if let summary { try summary.write(to: mf.summaryURL, atomically: true, encoding: .utf8) }
        if let notes { try notes.write(to: mf.notesURL, atomically: true, encoding: .utf8) }
        if let transcriptMarkdown { try transcriptMarkdown.write(to: mf.transcriptURL, atomically: true, encoding: .utf8) }
    }

    private func write(template id: String, _ text: String, folder: String) throws {
        let dir = root.appendingPathComponent(folder).appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
    }
}

private extension SearchIndex {
    /// Lets the synchronous assertions above call into the actor.
    nonisolated func searchSync(_ query: SearchQuery, now: Date) throws -> SearchResults {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await self.search(query, now: now)) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<SearchResults, Error>?
}
