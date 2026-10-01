import Foundation

/// Title for a meeting started from a detected call that has no matching
/// calendar event, e.g. "Zoom call 14:05".
public enum DetectedCallTitle {
    public static func make(
        appName: String?,
        at date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        let time = date.formatted(style)
        if let appName = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
            return "\(shortName(appName)) call \(time)"
        }
        return "Call \(time)"
    }

    /// "Microsoft Teams" reads better as "Teams call"; browsers read better
    /// as a generic web call.
    private static func shortName(_ appName: String) -> String {
        switch appName {
        case "Microsoft Teams": "Teams"
        case "Google Chrome", "Microsoft Edge", "Safari", "Firefox", "Brave", "Arc", "Vivaldi", "Opera": "Web"
        default: appName
        }
    }
}
