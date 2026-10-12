import Foundation

/// Fixes the spelling of names and terms you've told it about.
///
/// Speech models write what they hear, so "Coysh" comes out "Coish" and "Theresa" as "Teresa". Telling
/// Whisper the names up front (as a prompt) was tried and rejected: on real recordings it made the
/// transcript *shorter* (sentences dropped) and slower, and it breaks the turbo models outright. This
/// works on the finished text instead, so it can only change spellings, never lose words: a word (or run
/// of words, for "Evangelical Alliance") that is very close to a term in the list is replaced by the term.
public struct VocabularyCorrector: Sendable {
    private struct Term: Sendable {
        let text: String
        let words: [String]            // normalised: lowercase letters and digits only
        let normalised: String
        /// One word taken from a longer term ("Theresa" from "Theresa Stone"). People often say just the
        /// first name, but a lone word is easier to confuse with a real one, so these only fix misspellings.
        var isPart = false
    }

    private let terms: [Term]

    public var isEmpty: Bool { terms.isEmpty }

    public init(terms: [String]) {
        var seen = Set<String>()
        let whole: [Term] = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && seen.insert($0.lowercased()).inserted }
            .map { text in
                let words = text.split(whereSeparator: \.isWhitespace).map { Self.normalise(String($0)) }.filter { !$0.isEmpty }
                return Term(text: text, words: words, normalised: words.joined())
            }
            .filter { !$0.words.isEmpty }

        var known = Set(whole.map(\.normalised))
        var parts: [Term] = []
        for term in whole where term.words.count > 1 {
            for word in term.text.split(whereSeparator: \.isWhitespace) {
                let spelled = String(word.filter { $0.isLetter || $0.isNumber })
                let normalised = Self.normalise(spelled)
                guard normalised.count >= 6, known.insert(normalised).inserted else { continue }
                parts.append(Term(text: spelled, words: [normalised], normalised: normalised, isPart: true))
            }
        }
        // Longer terms first, so "Evangelical Alliance" wins over "Alliance".
        self.terms = (whole + parts).sorted { $0.words.count > $1.words.count }
    }

    public func correct(_ text: String) -> String {
        guard !terms.isEmpty else { return text }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map { Token(String($0)) }
        guard !tokens.isEmpty else { return text }

        for term in terms {
            let span = term.words.count
            guard tokens.count >= span else { continue }
            var i = 0
            while i + span <= tokens.count {
                let window = tokens[i..<(i + span)]
                let candidate = window.map(\.core).map(Self.normalise).joined()
                if Self.isCloseEnough(candidate, to: term.normalised, misspellingOnly: term.isPart) {
                    var replacement = tokens[i]
                    replacement.core = term.text
                    replacement.suffix = window.last!.suffix
                    replacement.possessive = window.last!.possessive
                    tokens.replaceSubrange(i..<(i + span), with: [replacement])
                }
                i += 1
            }
        }
        return tokens.map(\.rendered).joined(separator: " ")
    }

    // MARK: - Matching

    /// Close but not necessarily equal. Short terms need to be exact apart from capitalisation (a one-letter
    /// difference is a different word: "Paul"/"pull"); longer ones may be a letter or two out.
    private static func isCloseEnough(_ candidate: String, to term: String, misspellingOnly: Bool = false) -> Bool {
        guard !candidate.isEmpty, candidate.first == term.first else { return false }
        if candidate == term { return !misspellingOnly }
        guard term.count >= 5 else { return false }
        let distance = editDistance(Array(candidate), Array(term))
        let allowed = term.count >= 9 ? 2 : 1
        return distance <= allowed && abs(candidate.count - term.count) <= allowed
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func normalise(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A word with its punctuation taken off, so punctuation survives a replacement.
    private struct Token {
        var prefix = ""
        var core: String
        var possessive = ""            // "'s" or "’s"
        var suffix = ""

        init(_ raw: String) {
            var body = Substring(raw)
            while let first = body.first, !(first.isLetter || first.isNumber) { prefix.append(first); body = body.dropFirst() }
            while let last = body.last, !(last.isLetter || last.isNumber) { suffix = String(last) + suffix; body = body.dropLast() }
            for apostrophe in ["'s", "’s"] where body.hasSuffix(apostrophe) && body.count > apostrophe.count {
                possessive = apostrophe
                body = body.dropLast(apostrophe.count)
                break
            }
            core = String(body)
        }

        var rendered: String { prefix + core + possessive + suffix }
    }
}
