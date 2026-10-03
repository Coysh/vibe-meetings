import Foundation

/// Lightweight, dependency-free text-similarity helpers used to detect echoed
/// or duplicated transcript segments. All comparisons are case- and
/// punctuation-insensitive and operate on word tokens.
public enum TextSimilarity {

    /// Normalize to a list of lowercased alphanumeric word tokens.
    /// "Hey, John — how's it going?" -> ["hey", "john", "how", "s", "it", "going"]
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Like ``tokens(_:)`` but also returns each token's range in the original
    /// string, so a span of tokens can be cut out of the text while preserving
    /// the casing and punctuation of what remains.
    public static func tokenRanges(_ s: String) -> [(token: String, range: Range<String.Index>)] {
        var out: [(token: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isLetter || s[i].isNumber {
                if start == nil { start = i }
            } else if let st = start {
                out.append((String(s[st..<i]).lowercased(), st..<i))
                start = nil
            }
            i = s.index(after: i)
        }
        if let st = start {
            out.append((String(s[st..<s.endIndex]).lowercased(), st..<s.endIndex))
        }
        return out
    }

    /// Token equality tolerant of a single-character slip. Room reverb makes the
    /// mic's recognition of an echoed word come out slightly off ("deadlined" for
    /// "deadline"); exact equality would miss it. Only tokens of ≥4 characters
    /// get the tolerance — short words differ by one letter too easily.
    public static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 1 else { return false }
        // One edit leaves either the first or the last character untouched, so
        // this cheap check rejects almost every unrelated pair before we
        // allocate anything.
        guard a.first == b.first || a.last == b.last else { return false }
        return withinOneEdit(Array(a), Array(b))
    }

    private static func withinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count == b.count { i += 1; j += 1 }
            else if a.count > b.count { i += 1 }
            else { j += 1 }
        }
        edits += (a.count - i) + (b.count - j)
        return edits <= 1
    }

    /// Longest-common-subsequence alignment. Returns, for each of the `micCount`
    /// items, the index of the `sysCount`-side item it was matched to (or `nil`).
    /// `isMatch(i, j)` decides whether mic item `i` may pair with system item `j`.
    ///
    /// Order-aware: the same words in a different order only partially align, so
    /// a reply that happens to reuse the other party's vocabulary scores low
    /// while a genuine echo (same sequence) scores high.
    public static func lcsAlignment(
        micCount n: Int,
        sysCount m: Int,
        isMatch: (_ mic: Int, _ sys: Int) -> Bool
    ) -> [Int?] {
        var result = [Int?](repeating: nil, count: n)
        guard n > 0, m > 0 else { return result }
        let w = m + 1
        var dp = [Int](repeating: 0, count: (n + 1) * w)
        for i in 1...n {
            for j in 1...m {
                if isMatch(i - 1, j - 1) {
                    dp[i * w + j] = dp[(i - 1) * w + (j - 1)] + 1
                } else {
                    dp[i * w + j] = max(dp[(i - 1) * w + j], dp[i * w + (j - 1)])
                }
            }
        }
        var i = n, j = m
        while i > 0 && j > 0 {
            if isMatch(i - 1, j - 1) && dp[i * w + j] == dp[(i - 1) * w + (j - 1)] + 1 {
                result[i - 1] = j - 1
                i -= 1; j -= 1
            } else if dp[(i - 1) * w + j] >= dp[i * w + (j - 1)] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    /// Jaccard similarity of the word *sets* of two strings, in 0…1.
    /// Order-insensitive; good for "did the same words appear" questions.
    public static func jaccard(_ a: String, _ b: String) -> Double {
        let sa = Set(tokens(a)), sb = Set(tokens(b))
        if sa.isEmpty && sb.isEmpty { return 1 }
        if sa.isEmpty || sb.isEmpty { return 0 }
        let intersection = sa.intersection(sb).count
        let union = sa.union(sb).count
        return Double(intersection) / Double(union)
    }

    /// Directional containment: the fraction of `a`'s word tokens that also
    /// appear in `b`, in 0…1. Answers "how much of `a` is covered by `b`".
    ///
    /// Unlike ``jaccard(_:_:)``, this is *not* penalized when `b` carries extra
    /// words `a` lacks — so a *partial* copy (`a` dropped some words but added
    /// none) still scores high. That is exactly the echo case: the mic channel
    /// re-records the other party imperfectly, capturing a subset of their words.
    /// Because it is directional, a genuine utterance whose own words are absent
    /// from `b` stays low, so it does not falsely match.
    public static func containment(_ a: String, _ b: String) -> Double {
        let sa = Set(tokens(a)), sb = Set(tokens(b))
        if sa.isEmpty { return 0 }
        return Double(sa.intersection(sb).count) / Double(sa.count)
    }

    /// True when `a` and `b` are near-duplicates: either the shorter is a
    /// leading token-prefix of the longer, or their word sets overlap by at
    /// least `threshold` (Jaccard).
    public static func similar(_ a: String, _ b: String, threshold: Double = 0.7) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        if ta.isEmpty || tb.isEmpty { return false }

        // Token-prefix containment catches the common streaming case where one
        // window transcribed a leading fragment of what a later window (or the
        // other channel) captured in full.
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        if short.count >= 2, long.starts(with: short) { return true }

        return jaccard(a, b) >= threshold
    }
}
