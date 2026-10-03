import Foundation
import VMCore

/// Where a meeting should end up when the user files it.
///
/// This replaces a bare `URL?` where `nil` was shown as "(keep in current
/// location)" but actually meant "auto-file by person/organisation, creating
/// folders as needed" — so choosing "keep" silently moved the meeting.
enum FolderChoice: Hashable {
    /// File by the meeting's details (person / organisation), creating folders if needed.
    case automatic
    /// Leave the meeting exactly where it is.
    case keep
    /// A specific existing folder.
    case folder(URL)
}

enum FilingError: LocalizedError {
    case destinationMissing(String)

    var errorDescription: String? {
        switch self {
        case .destinationMissing(let name):
            return "The folder “\(name)” could not be found. It may have been moved or deleted."
        }
    }
}

/// Folder suggestion, auto-filing and moving, shared by the post-recording sheet
/// and the Organise (triage) sheet. Everything that can fail throws, so callers
/// can tell the user instead of silently leaving a meeting unfiled.
@MainActor
struct MeetingFiler {
    let env: AppEnvironment

    // MARK: Suggestions

    /// Best existing folder for this meeting: its calendar series, the person
    /// (1:1s), the organisation, then title keywords. `nil` if nothing fits.
    func suggestFolder(for meeting: Meeting, in folders: [FolderNode]) async -> URL? {
        if let sid = meeting.calendarSeriesID,
           let seriesFolder = await env.meetingStore.folderForSeries(sid) {
            return seriesFolder.url
        }

        if meeting.resolvedType == .oneOnOne,
           let person = meeting.person ?? meeting.attendees?.first(where: { $0.lowercased() != "you" }) {
            if let personFolder = await env.meetingStore.folderForPerson(person) {
                return personFolder.url
            }
            if let match = folder(named: person, in: folders) { return match.url }
        }

        if let org = meeting.org, !org.isEmpty, let match = folder(named: org, in: folders) {
            return match.url
        }

        let titleWords = meeting.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        for folder in folders {
            let lower = folder.name.lowercased()
            if titleWords.contains(where: { lower.contains($0.lowercased()) }) { return folder.url }
        }
        return nil
    }

    // MARK: Resolving a choice

    /// The folder to move into, or `nil` to leave the meeting where it is.
    /// A typed `newFolderPath` ("Clients/Acme") wins over the picker.
    func destination(
        for choice: FolderChoice,
        newFolderPath: String,
        meeting: Meeting,
        folders: [FolderNode]
    ) async throws -> URL? {
        let typed = newFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return try await createNestedFolders(path: typed) }
        switch choice {
        case .keep: return nil
        case .folder(let url): return url
        case .automatic: return try await autoFolder(for: meeting, folders: folders)
        }
    }

    /// Moves the meeting into `destination` unless it is already there.
    func move(meetingID: UUID, currentFolder: URL, to destination: URL) async throws {
        guard destination.standardizedFileURL != currentFolder.deletingLastPathComponent().standardizedFileURL else { return }
        let tree = await env.meetingStore.currentTree()
        guard let target = tree.node(at: destination) else {
            throw FilingError.destinationMissing(destination.lastPathComponent)
        }
        try await env.meetingStore.moveMeeting(id: meetingID, to: target)
    }

    /// "A/B/C": each component is created under the previous one if missing.
    func createNestedFolders(path: String) async throws -> URL? {
        guard let root = env.folderTree else { return nil }
        let components = path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        var parent = root
        for component in components {
            if let existing = parent.children.first(where: { !$0.isMeeting && $0.name.lowercased() == component.lowercased() }) {
                parent = existing
            } else {
                parent = try await env.meetingStore.createFolder(at: parent, name: component)
            }
        }
        return parent.url
    }

    // MARK: Automatic filing

    /// 1:1 → `<one-to-ones category>/<person>`; group → the matching organisation
    /// folder. Creates what's missing. `nil` when the meeting has neither.
    private func autoFolder(for meeting: Meeting, folders: [FolderNode]) async throws -> URL? {
        guard let root = env.folderTree else { return nil }

        if meeting.resolvedType == .oneOnOne,
           let person = meeting.person ?? meeting.attendees?.first(where: { $0.lowercased() != "you" }),
           !person.isEmpty {
            let parent = oneToOneCategory(in: folders) ?? root
            let lower = person.lowercased()
            if let existing = folders.first(where: {
                $0.name.lowercased() == lower
                    && $0.url.deletingLastPathComponent().standardizedFileURL == parent.url.standardizedFileURL
            }) ?? folders.first(where: { $0.name.lowercased() == lower }) {
                return existing.url
            }
            return try await env.meetingStore.createFolder(at: parent, name: person).url
        }

        if let org = meeting.org?.trimmingCharacters(in: .whitespacesAndNewlines), !org.isEmpty {
            let lower = org.lowercased()
            // e.g. "20-EA-Meetings" for org "EA".
            if let category = folders.first(where: { !$0.isMeeting && $0.name.lowercased().contains(lower) }) {
                return category.url
            }
            return try await env.meetingStore.createFolder(at: root, name: org).url
        }
        return nil
    }

    // MARK: Helpers

    private func folder(named name: String, in folders: [FolderNode]) -> FolderNode? {
        let lower = name.lowercased()
        return folders.first(where: { $0.name.lowercased() == lower })
            ?? folders.first(where: { $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased()) })
    }

    /// A folder that holds 1:1s ("10-One-to-Ones", "People", "1-1s").
    private func oneToOneCategory(in folders: [FolderNode]) -> FolderNode? {
        let patterns = ["one-to-one", "1-1", "1:1", "people", "one to one"]
        return folders.first { f in
            let lower = f.name.lowercased()
            return patterns.contains(where: { lower.contains($0) })
        }
    }
}
