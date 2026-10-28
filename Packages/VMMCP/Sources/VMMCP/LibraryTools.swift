import Foundation
import VMCore

/// A tool call that failed in a way the model should see (bad id, bad date…).
/// Reported as a tool result with `isError: true`, not as a JSON-RPC error.
public struct ToolError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The read-only meeting tools. Lists and search results are JSON; a single
/// meeting and its transcript are markdown, which reads better than escaped strings.
public struct LibraryTools: Sendable {
    public let library: MeetingLibrary

    public init(library: MeetingLibrary) {
        self.library = library
    }

    public static let definitions: [JSONValue] = [
        tool(
            name: "list_meetings",
            title: "List meetings",
            description: "List recorded meetings, newest first, with date, duration, folder and attendees. Filter by text, date range, folder or person. Use get_meeting for the summary and notes of one meeting.",
            properties: [
                "query": ["type": "string", "description": "Case-insensitive text matched against title, organisation, attendees, labels and folder."],
                "from": ["type": "string", "description": "Only meetings starting on or after this date (YYYY-MM-DD, local time) or ISO 8601 date-time."],
                "to": ["type": "string", "description": "Only meetings starting on or before this date (YYYY-MM-DD, inclusive) or ISO 8601 date-time."],
                "folder": ["type": "string", "description": "Only meetings in this folder or below it, e.g. \"Clients/Acme\"."],
                "person": ["type": "string", "description": "Only meetings with an attendee or speaker whose name contains this."],
                "limit": ["type": "integer", "description": "Maximum results (default 25, max 100).", "minimum": 1, "maximum": 100],
                "offset": ["type": "integer", "description": "Results to skip, for paging (default 0).", "minimum": 0],
            ],
            required: []
        ),
        tool(
            name: "search_meetings",
            title: "Search meetings",
            description: "Full-text search across meeting titles, attendees, summaries, notes and transcripts. Returns the best matches with timestamped transcript snippets. Use get_transcript to read around a snippet.",
            properties: [
                "query": ["type": "string", "description": "Words or a phrase to search for."],
                "from": ["type": "string", "description": "Only meetings starting on or after this date (YYYY-MM-DD) or ISO 8601 date-time."],
                "to": ["type": "string", "description": "Only meetings starting on or before this date (YYYY-MM-DD, inclusive) or ISO 8601 date-time."],
                "limit": ["type": "integer", "description": "Maximum meetings to return (default 10, max 50).", "minimum": 1, "maximum": 50],
            ],
            required: ["query"]
        ),
        tool(
            name: "get_meeting",
            title: "Get meeting",
            description: "One meeting's details, AI summary (including any action items) and the user's own notes.",
            properties: [
                "id": ["type": "string", "description": "Meeting id from list_meetings or search_meetings."],
            ],
            required: ["id"]
        ),
        tool(
            name: "get_transcript",
            title: "Get transcript",
            description: "A meeting's transcript as timestamped, speaker-labelled lines. Long transcripts are returned in pages: when truncated, call again with the startSeconds given at the end.",
            properties: [
                "id": ["type": "string", "description": "Meeting id."],
                "startSeconds": ["type": "number", "description": "Start from this many seconds into the meeting (default 0).", "minimum": 0],
                "maxChars": ["type": "integer", "description": "Maximum characters of transcript to return (default 40000, max 200000).", "minimum": 1000, "maximum": 200000],
            ],
            required: ["id"]
        ),
        tool(
            name: "list_folders",
            title: "List folders",
            description: "The folders meetings are filed in, with how many meetings each holds (including subfolders).",
            properties: [:],
            required: []
        ),
    ]

    private static func tool(name: String, title: String, description: String, properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": false,
            ],
            "annotations": [
                "title": .string(title),
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }

    /// Runs a tool and returns its text output.
    public func call(_ name: String, arguments: JSONValue) throws(ToolError) -> String {
        guard library.exists else {
            throw ToolError("The meetings folder \(library.root.path) does not exist or can't be read.")
        }
        switch name {
        case "list_meetings": return try listMeetings(arguments)
        case "search_meetings": return try searchMeetings(arguments)
        case "get_meeting": return try getMeeting(arguments)
        case "get_transcript": return try getTranscript(arguments)
        case "list_folders": return listFolders()
        default: throw ToolError("Unknown tool: \(name)")
        }
    }

    // MARK: - list_meetings

    private func listMeetings(_ args: JSONValue) throws(ToolError) -> String {
        let limit = min(max(args["limit"]?.intValue ?? 25, 1), 100)
        let offset = max(args["offset"]?.intValue ?? 0, 0)
        let range = try dateRange(args)
        let query = nonEmpty(args["query"]?.stringValue)?.lowercased()
        let folder = nonEmpty(args["folder"]?.stringValue)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let person = nonEmpty(args["person"]?.stringValue)?.lowercased()

        let matches = library.entries().filter { entry in
            let m = entry.meeting
            guard range.contains(m.startedAt) else { return false }
            if let folder, !folder.isEmpty {
                let path = entry.folderPath.lowercased()
                guard path == folder || path.hasPrefix(folder + "/") else { return false }
            }
            if let person {
                let names = (m.attendees ?? []) + m.participants.map(\.displayName)
                guard names.contains(where: { $0.lowercased().contains(person) }) else { return false }
            }
            if let query {
                let haystack = ([m.title, m.calendarTitle, m.org, entry.folderPath].compactMap { $0 }
                    + (m.attendees ?? []) + (m.labels ?? []) + m.tags).joined(separator: "\n").lowercased()
                guard haystack.contains(query) else { return false }
            }
            return true
        }

        let page = matches.dropFirst(offset).prefix(limit)
        let next = offset + page.count
        return JSONValue.fields([
            ("total", .int(matches.count)),
            ("offset", .int(offset)),
            ("nextOffset", next < matches.count ? .int(next) : nil),
            ("meetings", .array(page.map(info))),
        ]).jsonString
    }

    // MARK: - search_meetings

    private func searchMeetings(_ args: JSONValue) throws(ToolError) -> String {
        guard let query = nonEmpty(args["query"]?.stringValue) else { throw ToolError("query is required.") }
        let limit = min(max(args["limit"]?.intValue ?? 10, 1), 50)
        let range = try dateRange(args)
        let search = LibrarySearch(query: query)
        guard !search.terms.isEmpty else { throw ToolError("query has no searchable words.") }

        var hits: [(entry: MeetingLibrary.Entry, hit: LibrarySearch.Hit)] = []
        for entry in library.entries() where range.contains(entry.meeting.startedAt) {
            if let hit = search.score(entry, in: library) { hits.append((entry, hit)) }
        }
        hits.sort { a, b in
            a.hit.score != b.hit.score ? a.hit.score > b.hit.score : a.entry.meeting.startedAt > b.entry.meeting.startedAt
        }

        let results: [JSONValue] = hits.prefix(limit).map { h in
            var o = info(h.entry)
            if case .object(var dict) = o {
                dict["matchedIn"] = .array(h.hit.matchedIn.map { .string($0) })
                if !h.hit.snippets.isEmpty { dict["snippets"] = .array(h.hit.snippets.map { .string($0) }) }
                o = .object(dict)
            }
            return o
        }
        return JSONValue.fields([
            ("query", .string(query)),
            ("totalMatches", .int(hits.count)),
            ("results", .array(results)),
        ]).jsonString
    }

    // MARK: - get_meeting

    private func getMeeting(_ args: JSONValue) throws(ToolError) -> String {
        let entry = try meetingEntry(args)
        let m = entry.meeting
        var out = "# \(m.title)\n\n"
        out += "- id: \(m.id.uuidString)\n"
        out += "- started: \(Self.formatDate(m.startedAt))\n"
        if let endedAt = m.endedAt {
            out += "- ended: \(Self.formatDate(endedAt)) (\(endedAt.timeIntervalSince(m.startedAt).formattedDuration))\n"
        } else {
            out += "- in progress (or interrupted): no end time recorded\n"
        }
        out += "- folder: \(entry.folderPath)\n"
        out += "- type: \(m.resolvedType == .oneOnOne ? "1:1" : "group meeting")\n"
        if let calendarTitle = m.calendarTitle, calendarTitle != m.title { out += "- calendar event: \(calendarTitle)\n" }
        if let platform = m.meetingPlatform { out += "- platform: \(platform.displayName)\n" }
        if let org = m.org, !org.isEmpty { out += "- organisation: \(org)\n" }
        if let attendees = m.attendees, !attendees.isEmpty { out += "- attendees: \(attendees.joined(separator: ", "))\n" }
        let speakers = m.participants.map(\.displayName)
        if !speakers.isEmpty { out += "- transcript speakers: \(speakers.joined(separator: ", "))\n" }
        if let labels = m.labels, !labels.isEmpty { out += "- labels: \(labels.joined(separator: ", "))\n" }
        if let language = m.language { out += "- language: \(language)\n" }

        out += "\n## Summary\n\n"
        out += library.summary(for: entry) ?? "_No summary has been generated for this meeting._"
        out += "\n\n## Notes\n\n"
        out += library.notes(for: entry) ?? "_No notes._"
        out += "\n\nThe full transcript is available with get_transcript.\n"
        return out
    }

    // MARK: - get_transcript

    private func getTranscript(_ args: JSONValue) throws(ToolError) -> String {
        let entry = try meetingEntry(args)
        let startSeconds = max(args["startSeconds"]?.doubleValue ?? 0, 0)
        let maxChars = min(max(args["maxChars"]?.intValue ?? 40_000, 1000), 200_000)
        let m = entry.meeting

        var out = "# Transcript: \(m.title)\n"
        out += "\(Self.formatDate(m.startedAt))"
        if let duration = m.duration { out += " · \(duration.formattedDuration)" }
        out += "\n\n"

        let utterances = library.utterances(for: entry)
        if utterances.isEmpty {
            guard let markdown = library.markdownTranscript(for: entry) else {
                return out + "_This meeting has no transcript._\n"
            }
            if markdown.count <= maxChars { return out + markdown + "\n" }
            return out + markdown.prefix(maxChars) + "\n\n(Truncated at \(maxChars) characters; this transcript has no timings to page by.)\n"
        }

        let remaining = utterances.filter { $0.start >= startSeconds }
        var used = 0
        var nextStart: TimeInterval?
        for u in remaining {
            let line = "[\(u.start.formattedTimestamp)] \(u.speaker): \(u.text)\n"
            if used + line.count > maxChars, used > 0 {
                nextStart = u.start
                break
            }
            out += line
            used += line.count
        }
        if remaining.isEmpty {
            out += "_Nothing after \(startSeconds.formattedTimestamp)._\n"
        }
        if let nextStart {
            out += "\n(Truncated. Call get_transcript again with startSeconds=\(Int(nextStart)) to continue.)\n"
        }
        return out
    }

    // MARK: - list_folders

    private func listFolders() -> String {
        let folders = library.folders().map { f -> JSONValue in
            ["path": .string(f.path), "meetings": .int(f.meetingCount)]
        }
        return JSONValue.fields([("folders", .array(folders))]).jsonString
    }

    // MARK: - helpers

    private func info(_ entry: MeetingLibrary.Entry) -> JSONValue {
        let m = entry.meeting
        return .fields([
            ("id", .string(m.id.uuidString)),
            ("title", .string(m.title)),
            ("startedAt", .string(Self.formatDate(m.startedAt))),
            ("durationMinutes", m.duration.map { .int(Int(($0 / 60).rounded())) }),
            ("inProgress", m.endedAt == nil ? .bool(true) : nil),
            ("folder", .string(entry.folderPath)),
            ("type", .string(m.resolvedType == .oneOnOne ? "1:1" : "group")),
            ("org", nonEmpty(m.org).map { .string($0) }),
            ("attendees", .strings(m.attendees)),
            ("labels", .strings(m.labels)),
            ("platform", m.meetingPlatform.map { .string($0.displayName) }),
            ("hasSummary", .bool(library.hasSummary(entry))),
            ("hasNotes", .bool(library.hasNotes(entry))),
        ])
    }

    private func meetingEntry(_ args: JSONValue) throws(ToolError) -> MeetingLibrary.Entry {
        guard let raw = nonEmpty(args["id"]?.stringValue) else { throw ToolError("id is required.") }
        guard let id = UUID(uuidString: raw) else { throw ToolError("\"\(raw)\" is not a meeting id. Ids come from list_meetings or search_meetings.") }
        guard let entry = library.entry(id: id) else { throw ToolError("No meeting with id \(raw).") }
        return entry
    }

    private func dateRange(_ args: JSONValue) throws(ToolError) -> ClosedRange<Date> {
        let from = try nonEmpty(args["from"]?.stringValue).map { s throws(ToolError) in try Self.parseDate(s, endOfDay: false) } ?? .distantPast
        let to = try nonEmpty(args["to"]?.stringValue).map { s throws(ToolError) in try Self.parseDate(s, endOfDay: true) } ?? .distantFuture
        guard from <= to else { throw ToolError("from is after to.") }
        return from...to
    }

    /// `YYYY-MM-DD` (local day; `endOfDay` makes it inclusive) or ISO 8601 date-time.
    static func parseDate(_ s: String, endOfDay: Bool) throws(ToolError) -> Date {
        let parts = s.split(separator: "-")
        if parts.count == 3, s.count == 10,
           let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
           let day = Calendar.current.date(from: DateComponents(year: y, month: mo, day: d)) {
            guard endOfDay, let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return day }
            return next.addingTimeInterval(-0.001)
        }
        if let date = try? Date(s, strategy: .iso8601) { return date }
        if let date = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        throw ToolError("Can't read the date \"\(s)\". Use YYYY-MM-DD or an ISO 8601 date-time such as 2026-10-27T14:00:00Z.")
    }

    /// Local time with its offset, e.g. `2026-10-27T14:00:00+01:00`.
    static func formatDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
