import Foundation
import EventKit
import VMCore

/// A Sendable snapshot of an `EKEvent` carrying just the fields we use.
/// Constructed at the EventKit boundary; everything downstream consumes this
/// instead of `EKEvent` so the rest of the app stays free of EventKit imports.
public struct CalendarEvent: Sendable, Hashable, Identifiable {
    public let id: String          // EKEvent.eventIdentifier — per-occurrence
    public let seriesID: String    // calendarItemExternalIdentifier (or fallback) — per-series
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let notes: String?
    public let teamsJoinURL: URL?
    public let calendarID: String
    public let calendarTitle: String

    public var hasTeamsURL: Bool { teamsJoinURL != nil }
    public var platform: MeetingPlatform { hasTeamsURL ? .teams : .other }

    public init(
        id: String,
        seriesID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        teamsJoinURL: URL?,
        calendarID: String,
        calendarTitle: String
    ) {
        self.id = id
        self.seriesID = seriesID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
        self.teamsJoinURL = teamsJoinURL
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
    }
}

extension CalendarEvent {
    init(from ekEvent: EKEvent) {
        let teamsURL = TeamsURLDetector.detect(in: ekEvent)
        let externalID = ekEvent.calendarItemExternalIdentifier ?? ""
        let resolvedSeriesID = externalID.isEmpty
            ? CalendarEvent.fallbackSeriesID(for: ekEvent)
            : externalID

        self.init(
            id: ekEvent.eventIdentifier ?? UUID().uuidString,
            seriesID: resolvedSeriesID,
            title: ekEvent.title ?? "(untitled)",
            startDate: ekEvent.startDate,
            endDate: ekEvent.endDate,
            location: ekEvent.location?.nilIfEmpty,
            notes: ekEvent.notes?.nilIfEmpty,
            teamsJoinURL: teamsURL,
            calendarID: ekEvent.calendar.calendarIdentifier,
            calendarTitle: ekEvent.calendar.title
        )
    }

    /// Best-effort fallback when `calendarItemExternalIdentifier` is empty.
    /// Composes a stable hash from title, organizer, and the start-of-day so
    /// daily/weekly/monthly recurrences usually map back together.
    /// May be lost on calendar account migration — documented limitation.
    static func fallbackSeriesID(for ekEvent: EKEvent) -> String {
        let title = ekEvent.title ?? ""
        let organizer = ekEvent.organizer?.url.absoluteString ?? ""
        let dayBucket = Int(ekEvent.startDate.timeIntervalSinceReferenceDate / 86400)
        return "fallback:\(title)|\(organizer)|\(dayBucket)".djb2HashHex()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Tiny pure-Swift hash for the fallback series ID — we don't need
    /// cryptographic strength, just stability.
    func djb2HashHex() -> String {
        var hash: UInt64 = 5381
        for byte in self.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
