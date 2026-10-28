import Foundation
import VMCore

/// Keyword scoring across a meeting's metadata, summary, notes and transcript.
/// Weights follow the library chat's (`MeetingChatService`): title 3, org and
/// attendees 2, summary 2; notes 2 and transcript 1 are added here, plus a bonus
/// when the whole phrase appears.
struct LibrarySearch {
    let phrase: String
    let terms: [String]

    struct Hit {
        var score: Int
        var matchedIn: [String]
        var snippets: [String]
    }

    init(query: String) {
        phrase = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        terms = phrase
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && seen.insert($0).inserted }
    }

    func score(_ entry: MeetingLibrary.Entry, in library: MeetingLibrary) -> Hit? {
        let m = entry.meeting
        var hit = Hit(score: 0, matchedIn: [], snippets: [])

        func check(_ field: String, _ text: String?, weight: Int) -> Bool {
            guard let text = text?.lowercased(), !text.isEmpty else { return false }
            let matched = terms.filter { text.contains($0) }.count
            guard matched > 0 else { return false }
            hit.score += matched * weight
            if terms.count > 1, text.contains(phrase) { hit.score += weight * 2 }
            hit.matchedIn.append(field)
            return true
        }

        _ = check("title", [m.title, m.calendarTitle].compactMap { $0 }.joined(separator: "\n"), weight: 3)
        _ = check("attendees", ([m.org].compactMap { $0 } + (m.attendees ?? [])).joined(separator: "\n"), weight: 2)
        let summary = library.summary(for: entry)
        if check("summary", summary, weight: 2), let line = bestLine(in: summary) { hit.snippets.append("Summary: \(line)") }
        let notes = library.notes(for: entry)
        if check("notes", notes, weight: 2), let line = bestLine(in: notes) { hit.snippets.append("Notes: \(line)") }

        let utterances = library.utterances(for: entry)
        if !utterances.isEmpty {
            let lowered: [String] = utterances.map { $0.text.lowercased() }
            if check("transcript", lowered.joined(separator: "\n"), weight: 1) {
                // Best three lines, shown in meeting order.
                var ranked: [(index: Int, rank: Int)] = []
                for (i, lower) in lowered.enumerated() {
                    let r = rank(lower)
                    if r > 0 { ranked.append((i, r)) }
                }
                ranked.sort { $0.rank != $1.rank ? $0.rank > $1.rank : $0.index < $1.index }
                for i in ranked.prefix(3).map(\.index).sorted() {
                    let u = utterances[i]
                    hit.snippets.append("[\(u.start.formattedTimestamp)] \(u.speaker): \(excerpt(u.text))")
                }
            }
        } else {
            _ = check("transcript", library.markdownTranscript(for: entry), weight: 1)
        }

        return hit.score > 0 ? hit : nil
    }

    /// How well one line matches: terms present, with the whole phrase counting extra.
    private func rank(_ lower: String) -> Int {
        let matched = terms.filter { lower.contains($0) }.count
        return matched + (terms.count > 1 && lower.contains(phrase) ? terms.count : 0)
    }

    private func bestLine(in text: String?) -> String? {
        guard let text else { return nil }
        let best = text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .max { rank($0.lowercased()) < rank($1.lowercased()) }
        guard let best, rank(best.lowercased()) > 0 else { return nil }
        return excerpt(best)
    }

    /// Up to ~240 characters, centred on the first matching term.
    private func excerpt(_ text: String, width: Int = 240) -> String {
        guard text.count > width else { return text }
        let lower = text.lowercased()
        let anchor = ([phrase] + terms).lazy.compactMap { lower.range(of: $0) }.first
        let offset = anchor.map { lower.distance(from: lower.startIndex, to: $0.lowerBound) } ?? 0
        let startOffset = max(0, min(offset - width / 3, text.count - width))
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(start, offsetBy: width)
        return (startOffset > 0 ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}
