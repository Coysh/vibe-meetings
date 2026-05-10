import Foundation

/// UserDefaults-backed preferences for the calendar layer. Stored as the
/// **excluded** set rather than enabled set so newly-discovered calendars are
/// watched by default.
public final class CalendarPreferences: @unchecked Sendable {
    public static let shared = CalendarPreferences()

    private let defaults: UserDefaults
    private let excludedKey = "VibeMeetings.Calendar.ExcludedCalendarIDs"
    private let bannerKey = "VibeMeetings.Calendar.BannerEnabled"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var excludedCalendarIDs: Set<String> {
        get {
            lock.lock(); defer { lock.unlock() }
            let arr = defaults.stringArray(forKey: excludedKey) ?? []
            return Set(arr)
        }
        set {
            lock.lock(); defer { lock.unlock() }
            defaults.set(Array(newValue), forKey: excludedKey)
        }
    }

    public func isExcluded(_ calendarID: String) -> Bool {
        excludedCalendarIDs.contains(calendarID)
    }

    public func setExcluded(_ excluded: Bool, for calendarID: String) {
        var set = excludedCalendarIDs
        if excluded { set.insert(calendarID) } else { set.remove(calendarID) }
        excludedCalendarIDs = set
    }

    public var bannerEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            if defaults.object(forKey: bannerKey) == nil { return true }
            return defaults.bool(forKey: bannerKey)
        }
        set {
            lock.lock(); defer { lock.unlock() }
            defaults.set(newValue, forKey: bannerKey)
        }
    }
}
