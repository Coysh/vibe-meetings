import Foundation

public extension TimeInterval {
    /// Formats a positive interval as `hh:mm:ss` (or `mm:ss` if under an hour).
    var formattedTimestamp: String {
        let total = max(0, Int(self.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// Compact human-readable form: "43m 12s", "1h 02m".
    var formattedDuration: String {
        let total = max(0, Int(self.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}
