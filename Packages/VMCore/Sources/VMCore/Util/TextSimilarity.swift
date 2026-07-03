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
