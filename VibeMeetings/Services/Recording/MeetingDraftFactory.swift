import Foundation
import VMCalendar
import VMCore
import VMStorage

/// What the user asked to record.
enum MeetingStartRequest: Sendable {
    /// A specific calendar event.
    case event(CalendarEvent)
    /// A blank meeting with a typed title.
    case blank(title: String)
    /// A call detected from microphone activity; linked to `event` if one
    /// matched, otherwise titled after the app ("Zoom call 14:05").
    case detectedCall(appName: String?, platform: MeetingPlatform?, event: CalendarEvent?)
}

/// Builds the `MeetingDraft` for a start request and decides which folder it
/// goes in. Shared by the "New meeting" sheet and the one-click paths
/// (notifications, overlay, menu bar) so they file meetings identically.
@MainActor
enum MeetingDraftFactory {
    static func createMeeting(
        for request: MeetingStartRequest,
        env: AppEnvironment,
        fallbackParent: FolderNode?
    ) async throws -> MeetingHandle {
        let title: String
        let event: CalendarEvent?
        var platform: MeetingPlatform?
        let startedAt: Date

        switch request {
        case .event(let ev), .detectedCall(_, _, let ev?):
            title = ev.title
            event = ev
            platform = ev.platform
            // For events that have already started, anchor to now; for upcoming
            // events, anchor to the event start so the timestamps line up.
            startedAt = max(Date(), ev.startDate)
        case .blank(let t):
            title = t
            event = nil
            startedAt = Date()
        case .detectedCall(let appName, let appPlatform, nil):
            title = DetectedCallTitle.make(appName: appName, at: Date())
            event = nil
            platform = appPlatform
            startedAt = Date()
        }
        if case .detectedCall(_, let appPlatform?, _) = request, platform == .other {
            // The event had no join link; the app holding the mic knows better.
            platform = appPlatform
        }

        // Extract metadata from calendar event if applicable.
        var attendees: [String]?
        var org: String? = env.configuredOrgs.first // Default org
        if let ev = event {
            if !ev.attendeeNames.isEmpty {
                attendees = ev.attendeeNames
            }
            // Infer org from calendar title (strip common suffixes like " Calendar").
            let genericNames = ["calendar", "work", "personal", "home", "other"]
            let cleaned = ev.calendarTitle
                .replacingOccurrences(of: " Calendar", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && !genericNames.contains(cleaned.lowercased()) {
                org = cleaned
            }
        }

        // Auto-detect meeting type from title.
        let meetingType = MeetingType.detect(from: title)

        let draft = MeetingDraft(
            title: title,
            startedAt: startedAt,
            transcriptionEngine: EngineRef(kind: type(of: env.activeTranscriptionEngine).kind, version: "1"),
            summarizationEngine: EngineRef(kind: "ollama", version: "1"),
            modelId: env.selectedModelId,
            calendarEventID: event?.id,
            calendarSeriesID: event?.seriesID,
            meetingPlatform: platform,
            meetingType: meetingType,
            attendees: attendees,
            org: org
        )

        // Folder routing: series → person (for 1:1s) → org → parentFolder.
        let store = env.meetingStore
        let target: FolderNode
        if let sid = event?.seriesID,
           let existing = await store.folderForSeries(sid) {
            target = existing
        } else if meetingType == .oneOnOne,
                  let personName = attendees?.first(where: { $0.lowercased() != "you" }) ?? attendees?.first,
                  let personFolder = await store.folderForPerson(personName) {
            target = personFolder
        } else if let orgName = org,
                  let orgFolder = await store.folderForOrg(orgName) {
            target = orgFolder
        } else if let fallbackParent {
            target = fallbackParent
        } else {
            target = await store.currentTree()
        }

        return try await store.createMeeting(in: target, draft: draft)
    }
}
