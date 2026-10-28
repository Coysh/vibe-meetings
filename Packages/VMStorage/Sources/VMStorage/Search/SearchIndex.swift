import Foundation
import VMCore

/// Full-text index of the meeting library: titles and people, summaries, notes,
/// template write-ups and every transcript line.
///
/// It is a cache. It lives in Application Support (never in the library, which
/// stays plain files), can be deleted at any time, and is kept current by `sync`,
/// which re-reads only the meetings whose files changed.
public actor SearchIndex {
    /// Bump when the schema or what gets indexed changes; the index is then rebuilt.
    static let schemaVersion = 1

    public struct SyncStats: Sendable, Equatable {
        public let indexed: Int
        public let removed: Int
        public let total: Int
    }

    private let url: URL
    private var db: SQLiteDatabase?

    public init(databaseURL: URL) {
        self.url = databaseURL
    }

    /// `~/Library/Application Support/VibeMeetings/search-index.sqlite`.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VibeMeetings", isDirectory: true)
            .appendingPathComponent("search-index.sqlite")
    }

    // MARK: - Sync

    /// Brings the index in line with `tree`: indexes new and changed meetings and
    /// drops the ones that are gone. Yields between meetings so searches can run
    /// meanwhile, and stops early (leaving the rest for next time) when cancelled.
    @discardableResult
    public func sync(tree: FolderNode, root: URL, progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> SyncStats {
        let db = try database()
        let rootPath = root.standardizedFileURL.path
        if try meta("root") != rootPath {
            try db.transaction {
                for table in ["docs", "meetings", "meeting_people", "meeting_speakers", "meeting_labels"] {
                    try db.execute("DELETE FROM \(table)")
                }
                try setMeta("root", rootPath)
            }
        }

        let known = try Dictionary(
            db.prepare("SELECT id, signature FROM meetings").rows { ($0.text(0) ?? "", $0.text(1) ?? "") },
            uniquingKeysWith: { a, _ in a })

        var present = Set<String>()
        var changed: [(node: FolderNode, meeting: Meeting, folderPath: String, signature: String)] = []
        for node in tree.allMeetingNodes {
            guard let meeting = node.meeting else { continue }
            let id = meeting.id.uuidString
            guard present.insert(id).inserted else { continue } // a copied folder keeps its id; index the first
            let folderPath = Self.folderPath(ofMeetingAt: node.url, rootPath: rootPath)
            let signature = Self.signature(of: node.url, folderPath: folderPath)
            if known[id] != signature { changed.append((node, meeting, folderPath, signature)) }
        }

        let gone = Set(known.keys).subtracting(present)
        if !gone.isEmpty {
            try db.transaction {
                for id in gone { try deleteMeeting(id) }
            }
        }

        var done = 0
        for item in changed {
            if Task.isCancelled { break }
            try db.transaction {
                try index(item.meeting, folderURL: item.node.url, folderPath: item.folderPath, signature: item.signature)
            }
            done += 1
            progress?(done, changed.count)
            await Task.yield()
        }
        return SyncStats(indexed: done, removed: gone.count, total: present.count)
    }

    /// Empties the index (e.g. when the library moves); the next `sync` rebuilds it.
    public func reset() throws {
        db = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    // MARK: - Search

    public func search(_ query: SearchQuery, now: Date = .now) throws -> SearchResults {
        let db = try database()
        var clauses: [String] = []
        var params: [SQLValue] = []
        let f = query.filters

        if let range = f.dateRange {
            let i = range.interval(now: now)
            clauses.append("m.started_at >= ? AND m.started_at < ?")
            params += [.double(i.start.timeIntervalSince1970), .double(i.end.timeIntervalSince1970)]
        }
        if let folder = f.folderPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !folder.isEmpty {
            let prefix = folder + "/"
            clauses.append("(m.folder_path = ? OR substr(m.folder_path, 1, ?) = ?)")
            params += [.text(folder), .int(prefix.count), .text(prefix)]
        }
        if !f.people.isEmpty {
            clauses.append("m.id IN (SELECT meeting_id FROM meeting_people WHERE name IN (\(placeholders(f.people.count))))")
            params += f.people.sorted().map(SQLValue.text)
        }
        if let org = f.org {
            clauses.append("m.org = ?")
            params.append(.text(org))
        }
        if let type = f.meetingType {
            clauses.append("m.type = ?")
            params.append(.text(type.rawValue))
        }
        if !f.labels.isEmpty {
            clauses.append("m.id IN (SELECT meeting_id FROM meeting_labels WHERE label IN (\(placeholders(f.labels.count))))")
            params += f.labels.sorted().map(SQLValue.text)
        }
        if f.improvedOnly { clauses.append("m.improved = 1") }

        guard let terms = SearchQuery.terms(for: query.text) else {
            // Browse: the filtered meetings, newest first.
            if let speaker = f.speaker {
                clauses.append("m.id IN (SELECT meeting_id FROM meeting_speakers WHERE name = ?)")
                params.append(.text(speaker))
            }
            guard !clauses.isEmpty else { return .empty }
            let sql = "SELECT m.id, m.started_at FROM meetings m WHERE \(clauses.joined(separator: " AND ")) ORDER BY m.started_at DESC"
            let hits = try db.prepare(sql).rows(params) { row -> SearchHit? in
                guard let id = row.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
                return SearchHit(meetingID: id, startedAt: Date(timeIntervalSince1970: row.double(1) ?? 0),
                                 score: 0, bestKind: nil, snippets: [], transcriptMatches: 0)
            }
            return SearchResults(hits: hits.compactMap { $0 }, isBrowse: true)
        }

        var kinds = f.kinds
        if let speaker = f.speaker {
            kinds = [.transcript]
            clauses.append("d.speaker = ?")
            params.append(.text(speaker))
        }
        if !kinds.isEmpty, kinds.count < SearchKind.allCases.count {
            clauses.append("d.kind IN (\(placeholders(kinds.count)))")
            params += kinds.map(\.rawValue).sorted().map(SQLValue.text)
        }

        func whereClause(_ extra: [String] = []) -> String {
            (["docs_fts MATCH ?"] + clauses + extra).joined(separator: " AND ")
        }

        // Each word must appear somewhere in the meeting, not necessarily on the same
        // transcript line: narrow to the meetings that have them all.
        if terms.positives.count > 1 || !terms.negatives.isEmpty {
            let perTerm = try db.prepare("""
                SELECT DISTINCT d.meeting_id FROM docs_fts
                JOIN docs d ON d.rowid = docs_fts.rowid JOIN meetings m ON m.id = d.meeting_id
                WHERE \(whereClause())
                """)
            var candidates: Set<String>?
            for term in terms.positives {
                let ids = Set(try perTerm.rows([.text(term)] + params) { $0.text(0) }.compactMap { $0 })
                candidates = candidates.map { $0.intersection(ids) } ?? ids
                if candidates?.isEmpty == true { return .empty }
            }
            let anywhere = try db.prepare("SELECT DISTINCT d.meeting_id FROM docs_fts JOIN docs d ON d.rowid = docs_fts.rowid WHERE docs_fts MATCH ?")
            for term in terms.negatives {
                candidates?.subtract(try anywhere.rows([.text(term)]) { $0.text(0) }.compactMap { $0 })
            }
            guard let candidates, !candidates.isEmpty else { return .empty }
            try db.execute("CREATE TEMP TABLE IF NOT EXISTS candidates (id TEXT PRIMARY KEY)")
            try db.execute("DELETE FROM temp.candidates")
            let add = try db.prepare("INSERT INTO temp.candidates (id) VALUES (?)")
            for id in candidates { try add.run([.text(id)]) }
            clauses.append("d.meeting_id IN (SELECT id FROM temp.candidates)")
        }

        // Passages with any of the words; those with more of them rank higher.
        let expression = terms.positives.joined(separator: " OR ")
        let start = String(SearchSnippet.highlightStart), end = String(SearchSnippet.highlightEnd)
        let sql = """
            SELECT d.meeting_id, d.kind, d.speaker, d.start, d.segment_id, d.label,
                   bm25(docs_fts), snippet(docs_fts, 0, '\(start)', '\(end)', '…', 24), m.started_at
            FROM docs_fts
            JOIN docs d ON d.rowid = docs_fts.rowid
            JOIN meetings m ON m.id = d.meeting_id
            WHERE \(whereClause())
            ORDER BY bm25(docs_fts)
            LIMIT 3000
            """
        struct Match {
            let meetingID: UUID
            let startedAt: Double
            let score: Double
            let snippet: SearchSnippet
        }
        let matches = try db.prepare(sql).rows([.text(expression)] + params) { row -> Match? in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)),
                  let kind = row.text(1).flatMap(SearchKind.init(rawValue:)) else { return nil }
            // bm25 is negative, more negative for better matches.
            let score = -(row.double(6) ?? 0) * kind.weight
            let snippet = SearchSnippet(kind: kind, text: row.text(7) ?? "", speaker: row.text(2), start: row.double(3),
                                        segmentID: row.text(4).flatMap(UUID.init(uuidString:)), label: row.text(5))
            return Match(meetingID: id, startedAt: row.double(8) ?? 0, score: score, snippet: snippet)
        }.compactMap { $0 }

        // Matches arrive best first, so each meeting's lists are already in rank order.
        var order: [UUID] = []
        var byMeeting: [UUID: [Match]] = [:]
        for m in matches {
            if byMeeting[m.meetingID] == nil { order.append(m.meetingID) }
            byMeeting[m.meetingID, default: []].append(m)
        }
        var hits = order.map { id -> SearchHit in
            let rows = byMeeting[id]!
            let best = rows[0]
            // Further matches add a little, so a meeting that keeps coming back to the topic outranks a passing mention.
            let score = best.score + 0.2 * rows.dropFirst().prefix(5).reduce(0) { $0 + $1.score }
            let docs = rows.filter { $0.snippet.kind != .transcript && $0.snippet.kind != .title }
            let lines = rows.filter { $0.snippet.kind == .transcript }
            let shownDocs = docs.prefix(lines.isEmpty ? 3 : 1).map(\.snippet)
            let shownLines = lines.prefix(3 - shownDocs.count).map(\.snippet).sorted { ($0.start ?? 0) < ($1.start ?? 0) }
            return SearchHit(meetingID: id, startedAt: Date(timeIntervalSince1970: best.startedAt), score: score,
                             bestKind: best.snippet.kind, snippets: shownDocs + shownLines, transcriptMatches: lines.count)
        }
        switch query.sort {
        case .relevance: hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.startedAt > $1.startedAt }
        case .newest: hits.sort { $0.startedAt > $1.startedAt }
        }
        return SearchResults(hits: hits, isBrowse: false)
    }

    public func facets() throws -> SearchFacets {
        let db = try database()
        func values(_ sql: String) throws -> [SearchFacets.Value] {
            try db.prepare(sql).rows { SearchFacets.Value(name: $0.text(0) ?? "", count: $0.int(1) ?? 0) }
                .filter { !$0.name.isEmpty }
        }
        var f = SearchFacets()
        f.people = try values("SELECT name, COUNT(DISTINCT meeting_id) c FROM meeting_people GROUP BY name ORDER BY c DESC, name")
        f.speakers = try values("SELECT name, COUNT(DISTINCT meeting_id) c FROM meeting_speakers GROUP BY name ORDER BY c DESC, name")
        f.labels = try values("SELECT label, COUNT(DISTINCT meeting_id) c FROM meeting_labels GROUP BY label ORDER BY c DESC, label")
        f.orgs = try values("SELECT org, COUNT(*) c FROM meetings WHERE org IS NOT NULL AND org != '' GROUP BY org ORDER BY c DESC, org")
        f.meetingCount = try db.prepare("SELECT COUNT(*) FROM meetings").rows { $0.int(0) ?? 0 }.first ?? 0
        return f
    }

    // MARK: - Indexing one meeting

    private func index(_ meeting: Meeting, folderURL: URL, folderPath: String, signature: String) throws {
        let db = try database()
        let id = meeting.id.uuidString
        try deleteMeeting(id)

        let folder = MeetingFolder(url: folderURL)
        let fm = FileManager.default
        let improved = fm.fileExists(atPath: folderURL.appendingPathComponent(Self.refinedFilename).path)
        let summary = TranscriptText.readText(folder.summaryURL)

        try db.prepare("""
            INSERT INTO meetings (id, folder_path, title, started_at, ended_at, type, org, improved, has_summary, signature)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """).run([
                .text(id), .text(folderPath), .text(meeting.title),
                .double(meeting.startedAt.timeIntervalSince1970), .optional(meeting.endedAt?.timeIntervalSince1970),
                .text(meeting.resolvedType.rawValue), .optional(meeting.org?.nilIfBlank),
                .int(improved ? 1 : 0), .int(summary == nil ? 0 : 1), .text(signature),
            ])

        let addPerson = try db.prepare("INSERT OR IGNORE INTO meeting_people (meeting_id, name) VALUES (?, ?)")
        for name in Self.people(in: meeting) { try addPerson.run([.text(id), .text(name)]) }
        let addLabel = try db.prepare("INSERT OR IGNORE INTO meeting_labels (meeting_id, label) VALUES (?, ?)")
        for label in (meeting.labels ?? []).compactMap(\.nilIfBlank) { try addLabel.run([.text(id), .text(label)]) }

        let addDoc = try db.prepare("""
            INSERT INTO docs (meeting_id, kind, speaker, start, segment_id, label, body) VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        func doc(_ kind: SearchKind, _ body: String?, speaker: String? = nil, start: Double? = nil,
                 segmentID: UUID? = nil, label: String? = nil) throws {
            guard let body = body?.nilIfBlank else { return }
            try addDoc.run([.text(id), .text(kind.rawValue), .optional(speaker), .optional(start),
                            .optional(segmentID?.uuidString), .optional(label), .text(body)])
        }

        let titleText = ([meeting.title, meeting.calendarTitle].compactMap { $0 }
            + (meeting.attendees ?? []) + [meeting.org].compactMap { $0 })
            .compactMap(\.nilIfBlank)
        var seenTitle = Set<String>()
        try doc(.title, titleText.filter { seenTitle.insert($0.lowercased()).inserted }.joined(separator: "\n"))
        try doc(.summary, summary)
        try doc(.notes, TranscriptText.readText(folder.notesURL))

        let templatesDir = folderURL.appendingPathComponent("templates", isDirectory: true)
        let templateFiles = (try? fm.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil)) ?? []
        for file in templateFiles.filter({ $0.pathExtension == "md" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try doc(.template, TranscriptText.readText(file), label: file.deletingPathExtension().lastPathComponent)
        }

        let utterances = TranscriptText.utterances(meeting: meeting, folderURL: folderURL)
        if utterances.isEmpty {
            try doc(.transcript, TranscriptText.markdownTranscript(folderURL: folderURL))
        } else {
            let addSpeaker = try db.prepare("INSERT OR IGNORE INTO meeting_speakers (meeting_id, name) VALUES (?, ?)")
            for u in utterances {
                try doc(.transcript, u.text, speaker: u.speaker, start: u.start, segmentID: u.segmentID)
                try addSpeaker.run([.text(id), .text(u.speaker)])
            }
        }
    }

    private func deleteMeeting(_ id: String) throws {
        let db = try database()
        for table in ["docs", "meeting_people", "meeting_speakers", "meeting_labels"] {
            try db.prepare("DELETE FROM \(table) WHERE meeting_id = ?").run([.text(id)])
        }
        try db.prepare("DELETE FROM meetings WHERE id = ?").run([.text(id)])
    }

    /// Attendees and speakers who've been given a name (not the stock "You", "Others 2", "Speaker 1").
    static func people(in meeting: Meeting) -> [String] {
        let named = meeting.participants.map(\.displayName).filter { name in
            let lower = name.lowercased()
            return lower != "you" && lower != "imported" && !lower.hasPrefix("others") && !lower.hasPrefix("speaker")
        }
        var seen = Set<String>()
        return ((meeting.attendees ?? []) + named)
            .compactMap(\.nilIfBlank)
            .filter { $0.lowercased() != "you" && seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Change detection

    /// Written by the transcript refiner once a meeting has been transcribed again.
    static let refinedFilename = "refined.json"

    /// Size and modification time of every file the index reads, plus where the meeting is filed.
    static func signature(of folderURL: URL, folderPath: String) -> String {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        func stamp(_ url: URL) -> String {
            guard let v = try? url.resourceValues(forKeys: keys), let date = v.contentModificationDate else { return "-" }
            return "\(Int(date.timeIntervalSince1970 * 1000)):\(v.fileSize ?? 0)"
        }
        let names = [MeetingFolder.metadataFilename, MeetingFolder.segmentsFilename, MeetingFolder.summaryFilename,
                     MeetingFolder.notesFilename, MeetingFolder.transcriptFilename, refinedFilename]
        var parts = [folderPath] + names.map { "\($0)=\(stamp(folderURL.appendingPathComponent($0)))" }
        let templatesDir = folderURL.appendingPathComponent("templates", isDirectory: true)
        let templates = (try? FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: Array(keys))) ?? []
        for file in templates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            parts.append("templates/\(file.lastPathComponent)=\(stamp(file))")
        }
        return parts.joined(separator: "|")
    }

    /// The folder holding the meeting, relative to the root ("Clients/Acme"), or "" at the root.
    static func folderPath(ofMeetingAt url: URL, rootPath: String) -> String {
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        guard parentPath.hasPrefix(rootPath) else { return "" }
        return String(parentPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Database

    private func database() throws -> SQLiteDatabase {
        if let db { return db }
        do {
            db = try open()
        } catch {
            // A damaged cache is just rebuilt.
            try reset()
            db = try open()
        }
        return db!
    }

    private func open() throws -> SQLiteDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDatabase(url: url)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        let version = try db.prepare("PRAGMA user_version").rows { $0.int(0) ?? 0 }.first ?? 0
        if version != Self.schemaVersion {
            try db.transaction {
                for table in ["docs_fts", "docs", "meetings", "meeting_people", "meeting_speakers", "meeting_labels", "meta"] {
                    try db.execute("DROP TABLE IF EXISTS \(table)")
                }
                try db.execute(Self.schema)
                try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
        }
        return db
    }

    private static let schema = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE meetings (
            id TEXT PRIMARY KEY,
            folder_path TEXT NOT NULL,
            title TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            type TEXT,
            org TEXT COLLATE NOCASE,
            improved INTEGER NOT NULL DEFAULT 0,
            has_summary INTEGER NOT NULL DEFAULT 0,
            signature TEXT NOT NULL
        );
        CREATE INDEX meetings_started ON meetings(started_at);
        CREATE TABLE meeting_people (meeting_id TEXT NOT NULL, name TEXT NOT NULL COLLATE NOCASE, PRIMARY KEY (meeting_id, name));
        CREATE INDEX meeting_people_name ON meeting_people(name);
        CREATE TABLE meeting_speakers (meeting_id TEXT NOT NULL, name TEXT NOT NULL COLLATE NOCASE, PRIMARY KEY (meeting_id, name));
        CREATE INDEX meeting_speakers_name ON meeting_speakers(name);
        CREATE TABLE meeting_labels (meeting_id TEXT NOT NULL, label TEXT NOT NULL COLLATE NOCASE, PRIMARY KEY (meeting_id, label));
        CREATE INDEX meeting_labels_label ON meeting_labels(label);
        CREATE TABLE docs (
            rowid INTEGER PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            speaker TEXT COLLATE NOCASE,
            start REAL,
            segment_id TEXT,
            label TEXT,
            body TEXT NOT NULL
        );
        CREATE INDEX docs_meeting ON docs(meeting_id);
        CREATE VIRTUAL TABLE docs_fts USING fts5(
            body, content='docs', content_rowid='rowid',
            tokenize='porter unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER docs_ai AFTER INSERT ON docs BEGIN
            INSERT INTO docs_fts(rowid, body) VALUES (new.rowid, new.body);
        END;
        CREATE TRIGGER docs_ad AFTER DELETE ON docs BEGIN
            INSERT INTO docs_fts(docs_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
        END;
        """

    private func meta(_ key: String) throws -> String? {
        try database().prepare("SELECT value FROM meta WHERE key = ?").rows([.text(key)]) { $0.text(0) }.first ?? nil
    }

    private func setMeta(_ key: String, _ value: String) throws {
        try database().prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)").run([.text(key), .text(value)])
    }

    private func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ", ")
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
