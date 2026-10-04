import Foundation
import VMCore
import VMTranscription

// vm-diar-eval — run speaker diarization over saved recordings and report how
// many remote speakers it finds versus the meeting's invite list.
//
//   swift run -c release vm-diar-eval ~/MeetingNotes [--limit N] [--only substring] [--minutes M]
//
// Read-only on the meetings folder. Uses the system channel (right) of each
// meeting's audio.m4a — the other participants — exactly as the app will.

struct Options {
    var root = NSString(string: "~/MeetingNotes").expandingTildeInPath
    var limit = 40
    var only: [String] = []
    var minutes: Double = .infinity
    var show = false
}

func parseArgs() -> Options {
    var o = Options()
    var a = Array(CommandLine.arguments.dropFirst())
    if let first = a.first, !first.hasPrefix("--") { o.root = NSString(string: first).expandingTildeInPath; a.removeFirst() }
    var i = 0
    while i < a.count {
        switch a[i] {
        case "--limit": i += 1; o.limit = Int(a[i]) ?? o.limit
        case "--only": i += 1; o.only.append(a[i])
        case "--minutes": i += 1; o.minutes = Double(a[i]) ?? o.minutes
        case "--show": o.show = true
        default: break
        }
        i += 1
    }
    return o
}

func loadMeeting(_ dir: URL) -> Meeting? {
    guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("meeting.json").path) else { return nil }
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try? d.decode(Meeting.self, from: data)
}

let opts = parseArgs()
var dirs: [URL] = []
if let en = FileManager.default.enumerator(at: URL(fileURLWithPath: opts.root), includingPropertiesForKeys: nil) {
    for case let u as URL in en.allObjects where u.lastPathComponent == "audio.m4a" {
        let dir = u.deletingLastPathComponent()
        if !opts.only.isEmpty && !opts.only.contains(where: { dir.lastPathComponent.contains($0) }) { continue }
        dirs.append(dir)
    }
}
dirs.sort { $0.lastPathComponent > $1.lastPathComponent }

let diarizer = SpeakerDiarizer()
print("Preparing diarization models (first run downloads them)…")
let prepStart = Date()
do { try await diarizer.prepareModels() } catch { print("Model preparation failed: \(error)"); exit(1) }
print(String(format: "Models ready in %.1f s\n", Date().timeIntervalSince(prepStart)))

print("meeting                                              | min | type  | invited | clusters (speech share)                        | ×rt")
var done = 0
for dir in dirs where done < opts.limit {
    let name = String(dir.lastPathComponent.prefix(52)).padding(toLength: 52, withPad: " ", startingAt: 0)
    let meeting = loadMeeting(dir)
    let type = meeting?.resolvedType == .oneOnOne ? "1:1  " : "group"
    let invited = meeting?.attendees?.count.description ?? "-"
    do {
        var (samples, duration) = try StereoAudioLoader.loadSystemChannel(url: dir.appendingPathComponent("audio.m4a"))
        if opts.minutes.isFinite, duration > opts.minutes * 60 {
            samples = Array(samples.prefix(Int(opts.minutes * 60 * PCMChunk.sampleRate)))
            duration = opts.minutes * 60
        }
        guard duration > 20 else { continue }
        let policy = meeting.map(DiarizationAssigner.policy(for:)) ?? .diarize(maxSpeakers: nil)
        guard case .diarize(let maxSpeakers) = policy else {
            print("\(name) | \(String(format: "%3.0f", duration / 60)) | \(type) | \(invited.padding(toLength: 7, withPad: " ", startingAt: 0)) | skipped: 1:1, left as “Others”")
            done += 1
            continue
        }
        let start = Date()
        let turns = try await diarizer.diarize(samples: samples, maxSpeakers: maxSpeakers)
        let wall = Date().timeIntervalSince(start)
        var speech: [String: Double] = [:]
        for t in turns { speech[t.cluster, default: 0] += t.end - t.start }
        let total = max(speech.values.reduce(0, +), 1)
        let ranked = speech.sorted { $0.value > $1.value }
        let floor = max(15, 0.02 * total)
        let significant = ranked.filter { $0.value >= floor }.count
        let shares = ranked.prefix(6).map { String(format: "%.0f%%", 100 * $0.value / total) }.joined(separator: " ")
        print(String(format: "%@ | %3.0f | %@ | %7@ | %2d (speakers: %d)  %@ | %.0f",
                     name, duration / 60, type, invited, ranked.count, significant,
                     shares.padding(toLength: 28, withPad: " ", startingAt: 0), duration / max(wall, 0.001)))
        if opts.show, let data = FileManager.default.contents(atPath: dir.appendingPathComponent("segments.json").path),
           let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) {
            let result = DiarizationAssigner.assign(
                turns: turns.map { .init(start: $0.start, end: $0.end, cluster: $0.cluster) },
                segments: segments
            )
            print("    relabelled: \(result.changed) · speakers: \(result.speakers.map(\.displayName).joined(separator: ", "))")
            let from = Double(ProcessInfo.processInfo.environment["PREVIEW_FROM"] ?? "0") ?? 0
            let systemOnly = ProcessInfo.processInfo.environment["PREVIEW_SYSTEM_ONLY"] != nil
            for seg in result.segments.filter({ $0.start >= from && (!systemOnly || $0.channel == .system) }).prefix(60) {
                let who = seg.channel == .mic ? "You      " : (seg.speakerId == "others" ? "Others   " : "Speaker \(seg.speakerId.dropFirst(7))")
                print(String(format: "    [%02d:%02d] %@ %@", Int(seg.start) / 60, Int(seg.start) % 60, who, String(seg.text.prefix(80))))
            }
        }
        done += 1
    } catch {
        print("\(name) | skipped: \(error.localizedDescription)")
    }
}
