import XCTest
import VMCore
import VMStorage
@testable import VMMCP

/// Runs against a synthetic library in a temp directory — never the real one.
final class MCPServerTests: XCTestCase {
    private var root: URL!
    private var server: MCPServer!

    private let budgetID = UUID()
    private let standupID = UUID()
    private let importedID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vmmcp-\(UUID().uuidString)")
        let cal = Calendar.current
        let oct20 = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))!
        let oct27 = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14))!
        let sep1 = cal.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9))!

        var budget = makeMeeting(id: budgetID, title: "Budget review", start: oct27, minutes: 45, folder: "Clients/Acme")
        budget.attendees = ["Priya Shah", "Sam Lee"]
        budget.org = "Acme"
        try write(budget, folder: "Clients/Acme/Budget review", segments: [
            seg("you", 0, "Thanks for joining."),
            seg("you", 3, "Let's look at the numbers."),
            seg("others", 10, "The marketing budget is over by ten percent."),
            seg("others", 15, "We should cut the conference spend.", partial: true),
            seg("you", 20, "Agreed, the quarterly forecast needs updating."),
        ], summary: "## Summary\nMarketing budget overspent.\n\n## Action items\n- Update the quarterly forecast", notes: "Ask about travel")

        let standup = makeMeeting(id: standupID, title: "Team standup", start: oct20, minutes: 15, folder: "Internal")
        try write(standup, folder: "Internal/Team standup", segments: [
            seg("you", 0, "Quick round of updates."),
            seg("others", 5, "Nothing blocking."),
        ])

        var imported = makeMeeting(id: importedID, title: "Old import", start: sep1, minutes: nil, folder: "")
        imported.participants = [.imported]
        try write(imported, folder: "Old import", segments: nil,
                  transcriptMarkdown: "# Old import\n\n## Full transcript\n> [!note]- Expand transcript\n> Speaker labels are placeholders — rename if useful.\n>\n> **Imported** [00:00]\n> We talked about the budget.\n")

        server = MCPServer(library: MeetingLibrary(root: root), serverVersion: "test")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - protocol

    func testInitializeEchoesSupportedVersion() throws {
        let r = try request("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        XCTAssertEqual(r["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(r["result"]?["serverInfo"]?["name"], "vibe-meetings")
        XCTAssertNotNil(r["result"]?["capabilities"]?["tools"])
    }

    func testInitializeFallsBackToLatestVersion() throws {
        let r = try request("initialize", ["protocolVersion": "1999-01-01"])
        XCTAssertEqual(r["result"]?["protocolVersion"]?.stringValue, MCPServer.supportedProtocolVersions[0])
    }

    func testNotificationGetsNoResponse() {
        XCTAssertNil(server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
    }

    func testParseError() throws {
        let r = try JSONValue.decode(XCTUnwrap(server.handle(Data("{not json".utf8))))
        XCTAssertEqual(r["error"]?["code"], .int(-32700))
        XCTAssertEqual(r["id"], .null)
    }

    func testUnknownMethod() throws {
        let r = try request("resources/list")
        XCTAssertEqual(r["error"]?["code"], .int(-32601))
    }

    func testStringIdsArePreserved() throws {
        let data = try XCTUnwrap(server.handle(Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)))
        XCTAssertEqual(try JSONValue.decode(data)["id"], "abc")
    }

    func testToolsListIsReadOnly() throws {
        let r = try request("tools/list")
        guard case .array(let tools)? = r["result"]?["tools"] else { return XCTFail("no tools") }
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }.sorted(),
                       ["get_meeting", "get_transcript", "list_folders", "list_meetings", "search_meetings"])
        for tool in tools {
            XCTAssertEqual(tool["annotations"]?["readOnlyHint"], true)
            XCTAssertEqual(tool["inputSchema"]?["type"], "object")
        }
    }

    // MARK: - tools

    func testListMeetingsNewestFirst() throws {
        let r = try json(call("list_meetings"))
        XCTAssertEqual(r["total"], 3)
        XCTAssertEqual(ids(r["meetings"]), [budgetID, standupID, importedID])
        XCTAssertEqual(r["meetings"]?[0]?["folder"], "Clients/Acme")
        XCTAssertEqual(r["meetings"]?[0]?["durationMinutes"], 45)
        XCTAssertEqual(r["meetings"]?[0]?["hasSummary"], true)
        XCTAssertEqual(r["meetings"]?[2]?["inProgress"], true)
    }

    func testListMeetingsFilters() throws {
        XCTAssertEqual(ids(try json(call("list_meetings", ["from": "2026-10-20", "to": "2026-10-20"]))["meetings"]), [standupID])
        XCTAssertEqual(ids(try json(call("list_meetings", ["folder": "clients"]))["meetings"]), [budgetID])
        XCTAssertEqual(ids(try json(call("list_meetings", ["person": "priya"]))["meetings"]), [budgetID])
        XCTAssertEqual(ids(try json(call("list_meetings", ["query": "standup"]))["meetings"]), [standupID])
    }

    func testListMeetingsPaging() throws {
        let first = try json(call("list_meetings", ["limit": 2]))
        XCTAssertEqual(ids(first["meetings"]), [budgetID, standupID])
        XCTAssertEqual(first["nextOffset"], 2)
        let second = try json(call("list_meetings", ["limit": 2, "offset": 2]))
        XCTAssertEqual(ids(second["meetings"]), [importedID])
        XCTAssertNil(second["nextOffset"])
    }

    func testBadDateIsToolError() throws {
        let r = try request("tools/call", ["name": "list_meetings", "arguments": ["from": "last tuesday"]])
        XCTAssertEqual(r["result"]?["isError"], true)
    }

    func testSearchRanksAndSnippets() throws {
        let r = try json(call("search_meetings", ["query": "budget"]))
        XCTAssertEqual(ids(r["results"]), [budgetID, importedID])
        let snippets = r["results"]?[0]?["snippets"]
        XCTAssertTrue(snippets?.jsonString.contains("[00:10] Others: The marketing budget") == true)
        XCTAssertTrue(r["results"]?[0]?["matchedIn"]?.jsonString.contains("summary") == true)
    }

    func testSearchIgnoresPartialSegments() throws {
        let r = try json(call("search_meetings", ["query": "conference"]))
        XCTAssertEqual(r["totalMatches"], 0)
    }

    func testGetMeeting() throws {
        let text = try call("get_meeting", ["id": .string(budgetID.uuidString.lowercased())])
        XCTAssertTrue(text.hasPrefix("# Budget review"))
        XCTAssertTrue(text.contains("Update the quarterly forecast"))
        XCTAssertTrue(text.contains("Ask about travel"))
        XCTAssertTrue(text.contains("attendees: Priya Shah, Sam Lee"))
    }

    func testUnknownIdIsToolError() throws {
        for id in ["nope", UUID().uuidString] {
            let r = try request("tools/call", ["name": "get_meeting", "arguments": ["id": .string(id)]])
            XCTAssertEqual(r["result"]?["isError"], true)
        }
    }

    func testTranscriptMergesSpeakersAndSkipsPartials() throws {
        let text = try call("get_transcript", ["id": .string(budgetID.uuidString)])
        XCTAssertTrue(text.contains("[00:00] You: Thanks for joining. Let's look at the numbers.\n"))
        XCTAssertTrue(text.contains("[00:10] Others: The marketing budget is over by ten percent.\n"))
        XCTAssertFalse(text.contains("conference"))
        XCTAssertFalse(text.contains("Truncated"))
    }

    func testTranscriptPaging() throws {
        let first = try call("get_transcript", ["id": .string(budgetID.uuidString), "maxChars": 1000])
        XCTAssertFalse(first.contains("Truncated"))  // all of it fits

        let later = try call("get_transcript", ["id": .string(budgetID.uuidString), "startSeconds": 10])
        XCTAssertFalse(later.contains("Thanks for joining"))
        XCTAssertTrue(later.contains("[00:20] You: Agreed"))
    }

    func testTranscriptPagingTruncates() throws {
        var long = makeMeeting(id: UUID(), title: "Long", start: Date(), minutes: 60, folder: "")
        long.participants = [.you, .others]
        let sentence = String(repeating: "word ", count: 100)
        let segments = (0..<40).map { seg($0 % 2 == 0 ? "you" : "others", TimeInterval($0 * 30), sentence) }
        try write(long, folder: "Long", segments: segments)

        let text = try call("get_transcript", ["id": .string(long.id.uuidString), "maxChars": 5000])
        let marker = try XCTUnwrap(text.range(of: "startSeconds="))
        let next = Int(text[marker.upperBound...].prefix { $0.isNumber })
        XCTAssertNotNil(next)
        let rest = try call("get_transcript", ["id": .string(long.id.uuidString), "maxChars": 5000, "startSeconds": .int(next!)])
        XCTAssertTrue(rest.contains("[\(TimeInterval(next!).formattedTimestamp)]"))
    }

    func testMarkdownTranscriptFallback() throws {
        let text = try call("get_transcript", ["id": .string(importedID.uuidString)])
        XCTAssertTrue(text.contains("We talked about the budget."))
        XCTAssertFalse(text.contains("[!note]"))
    }

    func testListFolders() throws {
        let r = try json(call("list_folders"))
        guard case .array(let folders)? = r["folders"] else { return XCTFail("no folders") }
        let counts = Dictionary(uniqueKeysWithValues: folders.compactMap { f in f["path"]?.stringValue.map { ($0, f["meetings"]?.intValue ?? -1) } })
        XCTAssertEqual(counts["/"], 3)
        XCTAssertEqual(counts["Clients/Acme"], 1)
        XCTAssertEqual(counts["Internal"], 1)
    }

    func testMissingRootIsToolError() throws {
        let missing = MCPServer(library: MeetingLibrary(root: root.appendingPathComponent("nope")), serverVersion: "test")
        let message: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_meetings"]]
        let data = try XCTUnwrap(missing.handle(message.encoded()))
        XCTAssertEqual(try JSONValue.decode(data)["result"]?["isError"], true)
    }

    // MARK: - helpers

    private func request(_ method: String, _ params: JSONValue? = nil) throws -> JSONValue {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": 1, "method": .string(method)]
        if let params { message["params"] = params }
        let data = try XCTUnwrap(server.handle(JSONValue.object(message).encoded()))
        return try JSONValue.decode(data)
    }

    private func call(_ name: String, _ arguments: JSONValue = [:]) throws -> String {
        let r = try request("tools/call", ["name": .string(name), "arguments": arguments])
        XCTAssertEqual(r["result"]?["isError"], false, "tool \(name) failed: \(r.jsonString)")
        return try XCTUnwrap(r["result"]?["content"]?[0]?["text"]?.stringValue)
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.decode(Data(text.utf8))
    }

    private func ids(_ value: JSONValue?) -> [UUID] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { $0["id"]?.stringValue.flatMap(UUID.init(uuidString:)) }
    }

    private func makeMeeting(id: UUID, title: String, start: Date, minutes: Double?, folder: String) -> Meeting {
        Meeting(
            id: id, title: title, startedAt: start,
            endedAt: minutes.map { start.addingTimeInterval($0 * 60) },
            folderRelativePath: folder,
            transcriptionEngine: EngineRef(kind: "test", version: "1"),
            modelId: "test"
        )
    }

    private func seg(_ speaker: String, _ start: TimeInterval, _ text: String, partial: Bool = false) -> TranscriptSegment {
        TranscriptSegment(speakerId: speaker, channel: speaker == "you" ? .mic : .system,
                          start: start, end: start + 2, text: text, isPartial: partial)
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
}

private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
}
