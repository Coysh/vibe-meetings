import AVFoundation
import SwiftUI
import VMCalendar
import VMCore
import VMRecording
import VMStorage
import VMTranscription

/// A permission the user may need to grant for recording to work.
enum RecordingPermission {
    case microphone
    case systemAudio

    /// Deep link to the matching System Settings pane.
    var settingsURL: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .systemAudio:
            // "System Audio Recording Only" lives under Screen & System Audio Recording.
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        }
    }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        }
    }
}

/// Something wrong with an in-progress recording that the user should know about.
struct RecordingIssue: Identifiable, Equatable {
    let id: String
    /// One plain sentence: what is wrong and what it means for the recording.
    let message: String
    /// Technical detail for a tooltip.
    let detail: String?
    /// A permission the user can grant to fix it.
    let fix: RecordingPermission?
}

/// Bound to a single in-progress meeting; owns the `AudioCaptureCoordinator` and
/// the live transcription pipeline.
///
/// Audio capture starts *first*, before the transcription model is ready, so
/// nothing is lost while a model loads (or downloads, on first run). The model
/// then attaches to the audio that has been buffering.
@MainActor
@Observable
final class RecordingController {

    /// State of the live transcript, independent of whether audio is being recorded.
    enum TranscriptionStatus: Equatable {
        /// The model is loading; `progress` is set only while it is downloading.
        case loadingModel(progress: Double?)
        case live
        /// Audio is still being recorded, but no live transcript will appear.
        case unavailable(String)
    }

    var state: CaptureState = .idle
    var elapsed: TimeInterval = 0
    var micLevel: Float = -120
    var systemLevel: Float = -120
    var liveSegments: [TranscriptSegment] = []
    var meetingHandle: MeetingHandle?

    var transcriptionStatus: TranscriptionStatus = .loadingModel(progress: nil)
    /// Why the "Others" channel isn't being captured, if it isn't (usually the
    /// System Audio Recording permission). `nil` while it is working.
    var systemAudioIssue: String?
    /// Name of the microphone being recorded, for display.
    var micDeviceName = "System Default"
    /// What the echo canceller is doing, refreshed every couple of seconds; nil until it reports.
    var echoStats: EchoCancellationStats?
    /// Set when startup failed because a permission is missing.
    private(set) var failedPermission: RecordingPermission?
    /// True from pressing Stop until the transcript and metadata are on disk.
    var isFinishing = false

    /// The calendar event linked to this recording, if any. Used for auto-end detection.
    var linkedCalendarEvent: CalendarEvent?

    /// User's free-form notes taken during the meeting.
    var notes: String = ""

    /// Tracks the echo reduction background task so callers can await it.
    var echoReductionTask: Task<Bool, Never>?

    private let env: AppEnvironment
    private let coordinator = AudioCaptureCoordinator()
    private let merger = SegmentMerger()
    private var streamTasks: [Task<Void, Never>] = []
    private var clockTask: Task<Void, Never>?
    /// Periodically flushes the live transcript to disk so a crash mid-meeting
    /// never loses more than one interval's worth of speech.
    private var checkpointTask: Task<Void, Never>?
    private static let checkpointInterval: Duration = .seconds(10)
    /// Tracks the last mic UID we configured so we can detect settings changes.
    private var currentMicUID: String?
    /// When resuming an existing meeting, the new capture session starts its
    /// clock at ~0. This offset shifts incoming live segments so they land
    /// *after* the loaded history instead of colliding with it. 0 for a fresh
    /// recording.
    private var timelineOffset: TimeInterval = 0

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Problems to surface while recording (shown in the bar, the floating pill and the menu).
    var issues: [RecordingIssue] {
        var out: [RecordingIssue] = []
        if let detail = systemAudioIssue {
            out.append(RecordingIssue(
                id: "system-audio",
                message: "Not capturing the other participants. Their voices won't be in the recording or transcript.",
                detail: detail,
                fix: .systemAudio
            ))
        }
        if case .unavailable(let detail) = transcriptionStatus {
            out.append(RecordingIssue(
                id: "transcription",
                message: "No live transcript. Audio is still being recorded.",
                detail: detail,
                fix: nil
            ))
        }
        return out
    }

    // MARK: - Resume

    /// Resume recording for an existing meeting. Loads the previously saved
    /// segments so they appear in the live view, then starts a new audio
    /// capture session. The earlier audio is preserved as a backup file.
    func resume(handle: MeetingHandle) async {
        if let existing = try? await env.meetingStore.loadTranscript(for: handle.meeting.id) {
            for seg in existing { merger.ingest(seg) }
            // The fresh capture session restarts its clock at ~0, so offset the
            // new live segments past the end of the loaded history to avoid
            // overlapping timestamps (which would interleave and duplicate).
            timelineOffset = existing.map(\.end).max() ?? 0
            liveSegments = merger.displaySnapshot()
        }
        if let existingNotes = try? await env.meetingStore.loadNotes(for: handle.meeting.id) {
            notes = existingNotes
        }
        // Starting a capture session deletes the existing audio file. Keep the
        // earlier audio next to it so resuming can never destroy it.
        let audio = handle.folderURL.appendingPathComponent(MeetingFolder.audioFilename)
        if FileManager.default.fileExists(atPath: audio.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = handle.folderURL.appendingPathComponent("audio-before-resume-\(stamp).m4a")
            try? FileManager.default.moveItem(at: audio, to: backup)
        }
        // Clear endedAt so the meeting appears as in-progress again.
        var updated = handle.meeting
        updated.endedAt = nil
        try? FolderTreeScanner.writeMeeting(updated, to: MeetingFolder(url: handle.folderURL).metadataURL)

        await start(handle: handle)
    }

    // MARK: - Start

    func start(handle: MeetingHandle) async {
        meetingHandle = handle
        state = .preparing
        if let eventID = handle.meeting.calendarEventID {
            let events = await env.calendarService.upcomingEvents(within: 24 * 60 * 60)
            linkedCalendarEvent = events.first(where: { $0.id == eventID })
        }
        let audioURL = handle.folderURL.appendingPathComponent(MeetingFolder.audioFilename)

        // 1. Audio capture first. The PCM streams buffer, so the transcription
        //    model can attach later without losing anything.
        let micID = env.selectedMicDeviceID
        currentMicUID = env.selectedMicDeviceUID
        micDeviceName = env.selectedMicDeviceName
        await coordinator.configureEchoCancellation(
            enabled: env.echoCancellationEnabled,
            debugWAVURL: env.saveEchoCancelledMic ? handle.folderURL.appendingPathComponent("mic-aec.wav") : nil
        )
        do {
            try await coordinator.start(writingAudioTo: audioURL, micDeviceID: micID)
        } catch {
            failedPermission = Self.permissionIssue(for: error)
            state = .error(Self.describe(error, permission: failedPermission))
            return
        }
        state = .recording
        if !coordinator.systemAudioAvailable {
            systemAudioIssue = coordinator.systemAudioError ?? "The system audio tap could not start."
        }

        env.meetingEndDetector.recordingDidStart(event: linkedCalendarEvent)

        // Levels — also forwarded to the meeting-end detector for silence detection.
        let levelStream = coordinator.levels
        let detector = env.meetingEndDetector
        streamTasks.append(Task {
            for await snap in levelStream {
                self.micLevel = snap.mic
                self.systemLevel = snap.system
                detector.updateLevels(mic: snap.mic, system: snap.system)
            }
        })

        clockTask = Task {
            let started = Date()
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self.elapsed = Date().timeIntervalSince(started)
                ticks += 1
                if ticks % 8 == 0 { self.syncEchoFilterMode() }   // every ~2 s
            }
        }

        // Crash failsafe: checkpoint the transcript to disk on a timer. The
        // meeting keeps `endedAt == nil` while live, so if we crash the launch
        // recovery finds this checkpoint (and the crash-safe audio) intact.
        let meetingID = handle.meeting.id
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkpointInterval)
                guard let self, self.state == .recording else { continue }
                await self.checkpointTranscript(meetingID: meetingID)
            }
        }

        // 2. The transcription model loads (and downloads, on first run) while
        //    audio is already being recorded.
        streamTasks.append(Task { await self.startTranscription() })
    }

    private func startTranscription() async {
        let modelId = env.selectedModelId
        transcriptionStatus = .loadingModel(progress: nil)
        do {
            try await env.activeTranscriptionEngine.loadModel(id: modelId) { [weak self] progress in
                Task { @MainActor in self?.transcriptionStatus = .loadingModel(progress: progress) }
            }
        } catch {
            transcriptionStatus = .unavailable(
                "Couldn't load the transcription model (\(modelId)): \(error.localizedDescription)"
            )
            return
        }
        guard !Task.isCancelled, state == .recording || state == .paused else { return }

        // NOTE: these tasks capture `self` strongly so the controller stays
        // alive while recording; the cycle is broken in stop().
        let options = env.transcriptionOptions(for: meetingHandle?.meeting)
        merger.setVocabulary(VocabularyCorrector(terms: env.vocabularyTerms(for: meetingHandle?.meeting)))
        let micStream = env.activeTranscriptionEngine.transcribeStream(
            input: coordinator.micPCM, channel: .mic, speakerId: Speaker.you.id, options: options
        )
        let sysStream = env.activeTranscriptionEngine.transcribeStream(
            input: coordinator.systemPCM, channel: .system, speakerId: Speaker.others.id, options: options
        )
        streamTasks.append(Task {
            do { for try await seg in micStream { self.ingest(seg) } }
            catch { print("mic stream error: \(error)") }
        })
        streamTasks.append(Task {
            do { for try await seg in sysStream { self.ingest(seg) } }
            catch { print("sys stream error: \(error)") }
        })
        transcriptionStatus = .live
    }

    // MARK: - Live updates

    /// The text-level echo filter is the safety net behind acoustic cancellation.
    /// When the canceller has concluded the user is on headphones (no echo path),
    /// there is no echo to catch, so fall back to the conservative filter and
    /// don't risk dropping genuine speech that happens to resemble the far end.
    /// Not if it ever had to give up on a wrong echo path: then "no echo path"
    /// more likely means it couldn't find one, and the text filter is all there is.
    private func syncEchoFilterMode() {
        let stats = coordinator.echoStats
        echoStats = stats
        let headphones = stats?.mode == .bypass && (stats?.harmTrips ?? 0) == 0
        merger.setEchoConfig(headphones ? .conservative : .default)
    }

    /// Persist the current merged transcript to disk mid-recording. Segments are
    /// promoted to final so a recovered transcript reads cleanly.
    private func checkpointTranscript(meetingID: UUID) async {
        let snapshot = merger.finalSnapshot()
        guard !snapshot.isEmpty else { return }
        try? await env.meetingStore.replaceTranscript(snapshot, for: meetingID)
    }

    /// Switch the microphone mid-recording after the user changes it in
    /// Settings. Called by `AppEnvironment`, so it works with the window closed.
    func switchMicIfNeeded() {
        let newUID = env.selectedMicDeviceUID
        guard newUID != currentMicUID, state == .recording else { return }
        let previousUID = currentMicUID
        currentMicUID = newUID
        micDeviceName = env.selectedMicDeviceName
        let newDeviceID = env.selectedMicDeviceID
        Task {
            do {
                try await coordinator.switchMicDevice(to: newDeviceID)
            } catch {
                // The old device is no longer capturing either; tell the user.
                currentMicUID = previousUID
                env.presentError(error, while: "switch microphone")
            }
        }
    }

    private func ingest(_ seg: TranscriptSegment) {
        var seg = seg
        if timelineOffset > 0 {
            seg.start += timelineOffset
            seg.end += timelineOffset
        }
        merger.ingest(seg)
        liveSegments = merger.displaySnapshot()
    }

    // MARK: - Stop

    func stop() async -> CaptureResult? {
        guard state == .recording || state == .paused else { return nil }
        isFinishing = true
        defer { isFinishing = false }
        let result = try? await coordinator.stop()

        // Stopping the capture ends the audio streams, and the transcribers then decode what's left (the
        // last few seconds) and settle it. Give them a moment to finish rather than cutting them off.
        let transcribers = streamTasks
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in transcribers { await task.value } }
            group.addTask { try? await Task.sleep(for: .seconds(8)) }
            await group.next()
            group.cancelAll()
        }
        for t in streamTasks { t.cancel() }
        streamTasks.removeAll()
        clockTask?.cancel(); clockTask = nil
        checkpointTask?.cancel(); checkpointTask = nil

        if let handle = meetingHandle {
            // Persist the cleaned, finalized transcript (echo-deduped,
            // duplicate-collapsed, all partials promoted to final).
            let allSegments = merger.finalSnapshot()
            do {
                try await env.meetingStore.replaceTranscript(allSegments, for: handle.meeting.id)
            } catch {
                env.presentError(error, while: "save the transcript")
            }

            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    try await env.meetingStore.writeNotes(notes, for: handle.meeting.id)
                } catch {
                    env.presentError(error, while: "save your notes")
                }
            }

            // Keep the echo canceller's final diagnostics with the recording.
            if let stats = coordinator.echoStats, let data = try? JSONEncoder.pretty.encode(stats) {
                try? data.write(to: handle.folderURL.appendingPathComponent("aec-stats.json"))
            }

            var updated = handle.meeting
            updated.endedAt = Date()
            updated.hasAudio = result?.audioFileURL != nil
            try? FolderTreeScanner.writeMeeting(updated, to: MeetingFolder(url: handle.folderURL).metadataURL)
        }
        state = .idle

        // Post-process: echo reduction of the playback copy, in the background.
        if let handle = meetingHandle {
            let folder = MeetingFolder(url: handle.folderURL)
            let inputURL = folder.audioURL
            let outputURL = folder.cleanedAudioURL
            echoReductionTask = Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: inputURL.path) else { return false }
                return await AudioEchoReducer.reduceEcho(inputURL: inputURL, outputURL: outputURL)
            }
        }

        // NOTE: The caller (RecordingSessionService) clears the controller,
        // resets detection state and shows the post-recording sheet, so it can
        // read `meetingHandle` first.
        return result
    }

    // MARK: - Failure helpers

    /// Whether `error` means a permission is missing, so the UI can offer to fix it.
    private static func permissionIssue(for error: Error) -> RecordingPermission? {
        if let capture = error as? AudioCaptureError {
            switch capture {
            case .microphonePermissionDenied: return .microphone
            case .systemAudioPermissionDenied: return .systemAudio
            default: break
            }
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted { return .microphone }
        return nil
    }

    private static func describe(_ error: Error, permission: RecordingPermission?) -> String {
        if let permission {
            return "Vibe Meetings doesn't have \(permission.title) access. Allow it in System Settings, then try again."
        }
        return error.localizedDescription
    }
}

extension RecordingController {
    /// What the echo canceller is doing, in a few words, with a longer explanation for a tooltip.
    /// Nil when there is nothing useful to say yet (or no system audio to cancel against).
    var echoStatus: (text: String, detail: String)? {
        guard let stats = echoStats, systemAudioIssue == nil else { return nil }
        switch stats.mode {
        case .noReference:
            return nil
        case .active:
            var detail = "The other people's voices your microphone picks up from the speakers are being cancelled before transcription."
            if let erle = stats.erleDB, erle > 0 { detail += String(format: " Removing about %.0f dB.", erle) }
            if let delay = stats.delayMs { detail += String(format: " Speaker-to-mic delay %.0f ms.", delay) }
            return ("Echo cancelled", detail)
        case .bypass:
            if stats.harmTrips == 0 {
                return ("Headphones", "No speaker echo reaches your microphone, so it is transcribed as it is.")
            }
            return ("Echo not cancelled", "Your microphone doesn't match the call audio closely enough to cancel the speakers' echo from it (a Bluetooth speaker, or no echo at all). The transcript's own echo filter still applies.")
        case .recovering:
            return ("Echo: re-learning", "Cancellation was making your microphone worse, so it was stopped and the speaker-to-mic delay is being measured again.")
        }
    }
}

extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
