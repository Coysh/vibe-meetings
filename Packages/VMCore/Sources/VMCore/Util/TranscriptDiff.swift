import Foundation

/// Compares two transcripts of the same recording word by word: what the improved one has that the live one
/// missed, and what the live one had that the improved one dropped or spelled differently.
///
/// Each audio channel is compared on its own (the two sides of a call overlap in time, so merging them first
/// would scramble the word order), and the result follows the improved transcript's segments, so it reads like
/// the transcript with the changes marked. Case and punctuation are ignored when matching words.
public enum TranscriptDiff {

    public enum Kind: Sendable, Equatable {
        case same
        /// In the improved transcript only.
        case added
        /// In the live transcript only.
        case removed
    }

    public struct Token: Sendable, Equatable {
        public let text: String
        public let kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// One segment of the improved transcript, with its words marked.
    public struct Line: Sendable, Equatable, Identifiable {
        public let segment: TranscriptSegment
        public let tokens: [Token]
        public var id: UUID { segment.id }
    }

    public struct Result: Sendable, Equatable {
        public let lines: [Line]
        public let liveWords: Int
        public let improvedWords: Int
        public let added: Int
        public let removed: Int
    }

    public static func compare(live: [TranscriptSegment], improved: [TranscriptSegment]) -> Result {
        var tokens = [[Token]](repeating: [], count: improved.count)
        var liveWords = 0
        var improvedWords = 0
        var added = 0
        var removed = 0

        var channels: [AudioChannel] = []
        for channel in (improved.map(\.channel) + live.map(\.channel)) where !channels.contains(channel) {
            channels.append(channel)
        }

        for channel in channels {
            // The live words in time order; the improved words in the order the transcript has them.
            let liveWordList = live.filter { $0.channel == channel }
                .sorted { $0.start < $1.start }
                .flatMap { words(in: $0.text) }
            var improvedWordList: [(text: String, line: Int)] = []
            for (index, segment) in improved.enumerated() where segment.channel == channel {
                for word in words(in: segment.text) { improvedWordList.append((word, index)) }
            }
            liveWords += liveWordList.count
            improvedWords += improvedWordList.count

            let ops = align(liveWordList.map(key), improvedWordList.map { key($0.text) })
            // Words only the live transcript had go on the line of the improved word just before them
            // (or the first line, if they come first).
            var currentLine = improvedWordList.first?.line
            for op in ops {
                switch op {
                case .equal(_, let b):
                    let (text, line) = improvedWordList[b]
                    tokens[line].append(Token(text: text, kind: .same))
                    currentLine = line
                case .insert(let b):
                    let (text, line) = improvedWordList[b]
                    tokens[line].append(Token(text: text, kind: .added))
                    currentLine = line
                    added += 1
                case .delete(let a):
                    removed += 1
                    if let line = currentLine { tokens[line].append(Token(text: liveWordList[a], kind: .removed)) }
                }
            }
        }

        let lines = improved.enumerated().map { Line(segment: $1, tokens: tokens[$0]) }
        return Result(lines: lines, liveWords: liveWords, improvedWords: improvedWords, added: added, removed: removed)
    }

    // MARK: - Words

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// What two words are compared by: no case, no surrounding punctuation, straight apostrophes.
    static func key(_ word: String) -> String {
        let lowered = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let trimmed = lowered.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        return trimmed.isEmpty ? lowered : trimmed
    }

    // MARK: - Alignment

    enum Op: Equatable {
        case equal(Int, Int)   // index in live, index in improved
        case delete(Int)       // live only
        case insert(Int)       // improved only
    }

    /// The edits that turn `a` (live) into `b` (improved), in order.
    ///
    /// Patience diff: words that appear exactly once on each side and in the same order anchor the match, and
    /// what's between anchors is aligned the same way, recursively. That keeps each sub-problem small, so a
    /// long meeting where half the words changed doesn't need a huge edit-graph (the standard algorithm's
    /// memory grows with the square of the number of changes).
    static func align(_ a: [String], _ b: [String]) -> [Op] {
        var ops: [Op] = []
        ops.reserveCapacity(max(a.count, b.count))
        alignRange(a, b, aRange: 0..<a.count, bRange: 0..<b.count, into: &ops)
        return ops
    }

    /// Past this many words in a stretch with no anchors, the stretch is reported as replaced wholesale.
    private static let maxUnanchoredWords = 4000

    private static func alignRange(_ a: [String], _ b: [String], aRange: Range<Int>, bRange: Range<Int>, into ops: inout [Op]) {
        var aLo = aRange.lowerBound, aHi = aRange.upperBound
        var bLo = bRange.lowerBound, bHi = bRange.upperBound

        // Words the two sides share at the start and end.
        var prefix = 0
        while aLo + prefix < aHi, bLo + prefix < bHi, a[aLo + prefix] == b[bLo + prefix] { prefix += 1 }
        for k in 0..<prefix { ops.append(.equal(aLo + k, bLo + k)) }
        aLo += prefix; bLo += prefix

        var suffix = 0
        while aHi - suffix > aLo, bHi - suffix > bLo, a[aHi - suffix - 1] == b[bHi - suffix - 1] { suffix += 1 }
        aHi -= suffix; bHi -= suffix
        defer {
            for k in 0..<suffix { ops.append(.equal(aHi + k, bHi + k)) }
        }

        if aLo == aHi {
            for j in bLo..<bHi { ops.append(.insert(j)) }
            return
        }
        if bLo == bHi {
            for i in aLo..<aHi { ops.append(.delete(i)) }
            return
        }

        let anchors = uniqueAnchors(a, b, aRange: aLo..<aHi, bRange: bLo..<bHi)
        if anchors.isEmpty {
            diffSmall(a, b, aRange: aLo..<aHi, bRange: bLo..<bHi, into: &ops)
            return
        }
        var ai = aLo, bj = bLo
        for anchor in anchors {
            alignRange(a, b, aRange: ai..<anchor.a, bRange: bj..<anchor.b, into: &ops)
            ops.append(.equal(anchor.a, anchor.b))
            ai = anchor.a + 1
            bj = anchor.b + 1
        }
        alignRange(a, b, aRange: ai..<aHi, bRange: bj..<bHi, into: &ops)
    }

    /// Words that occur once on each side, in an order both sides agree on (the longest such run).
    private static func uniqueAnchors(_ a: [String], _ b: [String], aRange: Range<Int>, bRange: Range<Int>) -> [(a: Int, b: Int)] {
        var aCount: [String: Int] = [:], bCount: [String: Int] = [:]
        var bIndex: [String: Int] = [:]
        for i in aRange { aCount[a[i], default: 0] += 1 }
        for j in bRange { bCount[b[j], default: 0] += 1; bIndex[b[j]] = j }

        // Pairs in live order, then the longest increasing run of improved positions.
        var pairs: [(a: Int, b: Int)] = []
        for i in aRange where aCount[a[i]] == 1 && bCount[a[i]] == 1 {
            if let j = bIndex[a[i]] { pairs.append((i, j)) }
        }
        guard !pairs.isEmpty else { return [] }

        var tails: [Int] = []                       // pair index ending the best run of each length
        var previous = [Int](repeating: -1, count: pairs.count)
        for (p, pair) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].b < pair.b { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[p] = tails[lo - 1] }
            if lo == tails.count { tails.append(p) } else { tails[lo] = p }
        }
        var run: [(a: Int, b: Int)] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.append(pairs[cursor])
            cursor = previous[cursor]
        }
        return run.reversed()
    }

    /// A stretch with no anchors, aligned by the standard diff.
    private static func diffSmall(_ a: [String], _ b: [String], aRange: Range<Int>, bRange: Range<Int>, into ops: inout [Op]) {
        let n = aRange.count, m = bRange.count
        guard n + m <= maxUnanchoredWords else {
            for i in aRange { ops.append(.delete(i)) }
            for j in bRange { ops.append(.insert(j)) }
            return
        }
        let difference = Array(b[bRange]).difference(from: Array(a[aRange]))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, removed.contains(i) {
                ops.append(.delete(aRange.lowerBound + i)); i += 1
            } else if j < m, inserted.contains(j) {
                ops.append(.insert(bRange.lowerBound + j)); j += 1
            } else {
                ops.append(.equal(aRange.lowerBound + i, bRange.lowerBound + j)); i += 1; j += 1
            }
        }
    }
}
