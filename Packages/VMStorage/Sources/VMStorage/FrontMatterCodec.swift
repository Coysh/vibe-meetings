import Foundation

/// Tiny YAML front-matter codec scoped to the keys we emit. Not a general YAML parser;
/// it round-trips the strict subset our writers produce.
///
/// Supported value shapes:
///   - scalar string  : "title: Weekly sync"
///   - scalar number  : "duration: 2592"
///   - scalar bool    : "hasAudio: true"
///   - ISO-8601 date  : "startedAt: 2026-05-10T14:00:00Z"
///   - flat list      : "tags: [product, weekly]"
///   - list of dicts  : two-space indented "- key: value" blocks (for participants)
public enum FrontMatterCodec {
    public static let openDelim = "---"
    public static let closeDelim = "---"

    /// Splits raw markdown into (front-matter dict, body). If no front-matter, returns ([:], whole input).
    public static func split(_ raw: String) -> (header: [String: Any], body: String) {
        var lines = raw.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == openDelim else {
            return ([:], raw)
        }
        lines.removeFirst()
        var headerLines: [String] = []
        while let line = lines.first, line.trimmingCharacters(in: .whitespaces) != closeDelim {
            headerLines.append(line)
            lines.removeFirst()
        }
        if !lines.isEmpty { lines.removeFirst() } // closing ---
        return (parse(headerLines), lines.joined(separator: "\n"))
    }

    /// Renders a header dictionary back into a `---` … `---` block. Keys are emitted in the
    /// caller-controlled order.
    public static func render(orderedHeader: [(String, Any)]) -> String {
        var out = "\(openDelim)\n"
        for (key, value) in orderedHeader {
            out += renderEntry(key: key, value: value, indent: 0)
        }
        out += "\(closeDelim)\n"
        return out
    }

    // MARK: - parse

    private static func parse(_ lines: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

                if rest.isEmpty {
                    // Possibly a list of dicts on subsequent indented lines.
                    var listItems: [[String: Any]] = []
                    var current: [String: Any] = [:]
                    i += 1
                    while i < lines.count {
                        let next = lines[i]
                        let trimmed = next.trimmingCharacters(in: .whitespaces)
                        if next.hasPrefix("  - ") {
                            if !current.isEmpty { listItems.append(current); current = [:] }
                            let kv = String(next.dropFirst(4))
                            if let c2 = kv.firstIndex(of: ":") {
                                let k = String(kv[..<c2]).trimmingCharacters(in: .whitespaces)
                                let v = String(kv[kv.index(after: c2)...]).trimmingCharacters(in: .whitespaces)
                                current[k] = scalar(v)
                            }
                        } else if next.hasPrefix("    ") && trimmed.contains(":") {
                            let kv = trimmed
                            if let c2 = kv.firstIndex(of: ":") {
                                let k = String(kv[..<c2]).trimmingCharacters(in: .whitespaces)
                                let v = String(kv[kv.index(after: c2)...]).trimmingCharacters(in: .whitespaces)
                                current[k] = scalar(v)
                            }
                        } else {
                            break
                        }
                        i += 1
                    }
                    if !current.isEmpty { listItems.append(current) }
                    out[key] = listItems
                    continue
                } else if rest.hasPrefix("[") && rest.hasSuffix("]") {
                    let inner = String(rest.dropFirst().dropLast())
                    let items = inner.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                    out[key] = items
                } else {
                    out[key] = scalar(rest)
                }
            }
            i += 1
        }
        return out
    }

    private static func scalar(_ raw: String) -> Any {
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if unquoted == "true" { return true }
        if unquoted == "false" { return false }
        if let i = Int(unquoted) { return i }
        if let d = Double(unquoted) { return d }
        return unquoted
    }

    // MARK: - render

    private static func renderEntry(key: String, value: Any, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        if let arr = value as? [String] {
            let escaped = arr.map { needsQuotes($0) ? "\"\($0)\"" : $0 }
            return "\(pad)\(key): [\(escaped.joined(separator: ", "))]\n"
        }
        if let arr = value as? [[String: Any]] {
            var s = "\(pad)\(key):\n"
            for item in arr {
                var first = true
                for (k, v) in item {
                    let prefix = first ? "  - " : "    "
                    s += "\(pad)\(prefix)\(k): \(renderScalar(v))\n"
                    first = false
                }
            }
            return s
        }
        return "\(pad)\(key): \(renderScalar(value))\n"
    }

    private static func renderScalar(_ value: Any) -> String {
        if let d = value as? Date {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            return fmt.string(from: d)
        }
        if let s = value as? String {
            return needsQuotes(s) ? "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\"" : s
        }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(d) }
        return "\(value)"
    }

    private static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s.contains(":") || s.contains("#") || s.hasPrefix("- ") { return true }
        if s.first == " " || s.last == " " { return true }
        return false
    }
}
