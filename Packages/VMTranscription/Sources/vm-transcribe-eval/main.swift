import Foundation
import VMCore
import VMTranscription

// vm-transcribe-eval — measure transcription accuracy on saved recordings.
//
//   swift run -c release vm-transcribe-eval <meeting-folder>... [options]
//
//   --model <id>        offline reference pass (default whisper-large-v3-turbo)
//   --live              also replay the audio through the LIVE pipeline, old and new, and score both
//   --live-model <id>   model for the live replays (default whisper-medium, what the app uses today)
//   --minutes <n>       only the first n minutes of each recording (default 10)
//   --prompt "<text>"   vocabulary hint: names and terms to spell this way
//   --show <n>          most-different two-minute windows to print per speaker (default 0)
//   --save <dir>        write each transcript as <dir>/<meeting>.<label>.txt
//
// Read-only on the meetings folder; nothing leaves this Mac. "Disagreement" is the word error rate of a
// transcript taking the OFFLINE reference as truth — how far apart they are, not which is right.
// "Words per speech minute" needs no reference: people speak at roughly 120–170 words a minute while
// they're talking, so a transcript far below that has lost words.

struct Options {
    var folders: [URL] = []
    var model = "whisper-large-v3-turbo"
    var liveModel = "whisper-medium"
    var live = false
    var skipOld = false
    var hop = 3.0
    var context = 0
    var minutes = 10.0
    var prompt: String?
    var vocabulary: [String] = []
    var show = 0
    var save: URL?
}

func parse() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())[...]
    while let arg = args.popFirst() {
        switch arg {
        case "--model": options.model = args.popFirst() ?? options.model
        case "--live-model": options.liveModel = args.popFirst() ?? options.liveModel
        case "--live": options.live = true
        case "--skip-old": options.skipOld = true
        case "--hop": options.hop = Double(args.popFirst() ?? "") ?? options.hop
        case "--context": options.context = Int(args.popFirst() ?? "") ?? options.context
        case "--minutes": options.minutes = Double(args.popFirst() ?? "") ?? options.minutes
        case "--prompt": options.prompt = args.popFirst()
        case "--vocab": options.vocabulary = (args.popFirst() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "--show": options.show = Int(args.popFirst() ?? "") ?? options.show
        case "--save": options.save = args.popFirst().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        default: options.folders.append(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
        }
    }
    return options
}

func words(_ text: String) -> [String] {
    text.lowercased()
        .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        .map(String.init)
}

/// Word-level edit distance (substitutions + insertions + deletions).
func editDistance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

func clock(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }

struct Window {
    var candidate: [String] = []
    var reference: [String] = []
    var candidateText = ""
    var referenceText = ""
}

/// Compare per speaker, in two-minute windows (so a shifted boundary can't throw the whole file off).
func score(label: String, candidate: [TranscriptSegment], reference: [TranscriptSegment],
           limit: Double, speech: [String: Double], show: Int) {
    for (name, speaker) in [("You   ", Speaker.you.id), ("Others", Speaker.others.id)] {
        var windows: [Int: Window] = [:]
        for segment in candidate where segment.speakerId == speaker && segment.start < limit {
            windows[Int(segment.start / 120), default: Window()].candidate += words(segment.text)
            windows[Int(segment.start / 120), default: Window()].candidateText += " " + segment.text
        }
        for segment in reference where segment.speakerId == speaker && segment.start < limit {
            windows[Int(segment.start / 120), default: Window()].reference += words(segment.text)
            windows[Int(segment.start / 120), default: Window()].referenceText += " " + segment.text
        }
        let candidateWords = windows.values.reduce(0) { $0 + $1.candidate.count }
        let referenceWords = windows.values.reduce(0) { $0 + $1.reference.count }
        let edits = windows.values.reduce(0) { $0 + editDistance($1.candidate, $1.reference) }
        let rate = referenceWords == 0 ? 0 : Double(edits) / Double(referenceWords) * 100
        let speechMinutes = (speech[speaker] ?? 0) / 60
        let wpm = speechMinutes > 0.2 ? String(format: "%5.0f", Double(candidateWords) / speechMinutes) : "    -"
        print(String(format: "   %@ %@  %5d words  %@ words/speech-min   disagreement with reference %5.1f%%",
                     label.padding(toLength: 14, withPad: " ", startingAt: 0), name, candidateWords, wpm, rate))

        guard show > 0 else { continue }
        let worst = windows.sorted { editDistance($0.value.candidate, $0.value.reference) > editDistance($1.value.candidate, $1.value.reference) }.prefix(show)
        for (key, window) in worst where editDistance(window.candidate, window.reference) > 8 {
            print("       [\(clock(Double(key * 120)))] \(label): \(String(window.candidateText.trimmingCharacters(in: .whitespaces).prefix(220)))")
            print("       [\(clock(Double(key * 120)))] reference: \(String(window.referenceText.trimmingCharacters(in: .whitespaces).prefix(220)))")
        }
    }
}

/// Feed a channel through the live transcriber as capture would, 100 ms at a time. Time is the audio's own,
/// so the model is effectively keeping up with real time; the wall-clock tells us if it really could.
func replayLive(engine: WhisperKitEngine, samples: [Float], channel: AudioChannel, speaker: Speaker,
                commit: Bool, prompt: String?, hop: Double, context: Int) async -> (segments: [TranscriptSegment], wall: Double) {
    let (stream, continuation) = AsyncStream<PCMChunk>.makeStream()
    let step = 1_600
    var index = 0
    while index < samples.count {
        let end = min(samples.count, index + step)
        continuation.yield(PCMChunk(samples: Array(samples[index..<end]), timestamp: Double(index) / PCMChunk.sampleRate))
        index = end
    }
    continuation.finish()

    var options = TranscriptionOptions(language: "en", enableWordTimestamps: false, commitStreaming: commit, liveHopSeconds: hop, liveContextCharacters: context)
    options.initialPrompt = prompt
    let started = Date()
    var out: [TranscriptSegment] = []
    let merger = SegmentMerger()
    do {
        for try await segment in engine.transcribeStream(input: stream, channel: channel, speakerId: speaker.id, options: options) {
            merger.ingest(segment)
        }
        out = merger.snapshot()
    } catch {
        print("   live replay failed: \(error.localizedDescription)")
    }
    return (out, Date().timeIntervalSince(started))
}

func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
    let merger = SegmentMerger()
    for segment in segments.sorted(by: { $0.start < $1.start }) { merger.ingest(segment) }
    return merger.finalSnapshot()
}

func load(_ id: String) async -> WhisperKitEngine? {
    let engine = WhisperKitEngine()
    print("Loading \(id)…")
    do {
        try await engine.loadModel(id: id) { _ in }
        return engine
    } catch {
        print("Couldn't load \(id): \(error.localizedDescription)")
        return nil
    }
}

func evaluate(folder: URL, reference engine: WhisperKitEngine, liveEngine: WhisperKitEngine?, options: Options) async {
    let name = folder.lastPathComponent
    let audio = folder.appendingPathComponent("audio.m4a")
    guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent("segments.json").path),
          let saved = try? JSONDecoder().decode([TranscriptSegment].self, from: data), !saved.isEmpty
    else { print("• \(name): skipped (no saved live transcript)"); return }
    guard FileManager.default.fileExists(atPath: audio.path) else { print("• \(name): skipped (no audio.m4a)"); return }
    if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains(where: { $0.hasPrefix("audio-before-resume") }) == true {
        print("• \(name): skipped (resumed meeting: the audio file covers only part of the transcript)"); return
    }

    let limit = options.minutes * 60
    var transcription = TranscriptionOptions(language: "en", enableWordTimestamps: false)
    transcription.initialPrompt = options.prompt

    do {
        let reference = try await TranscriptRefiner.refine(
            audioURL: audio, engine: engine, options: transcription, vocabulary: options.vocabulary, maxSeconds: limit, progress: { _ in true }
        )
        print("\n== \(name)  (first \(clock(reference.audioSeconds)); reference pass \(clock(reference.elapsedSeconds)) = \(String(format: "%.1f", reference.audioSeconds / max(reference.elapsedSeconds, 0.1)))x real time)")

        func save(_ label: String, _ segments: [TranscriptSegment]) {
            guard let dir = options.save else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let text = segments.map { "[\(clock($0.start))] \($0.speakerId): \($0.text)" }.joined(separator: "\n")
            try? text.write(to: dir.appendingPathComponent("\(name).\(label).txt"), atomically: true, encoding: .utf8)
        }
        save("reference", reference.segments)
        let speech = reference.speechSeconds

        score(label: "reference", candidate: reference.segments, reference: reference.segments, limit: limit, speech: speech, show: 0)
        score(label: "saved live", candidate: saved, reference: reference.segments, limit: limit, speech: speech, show: options.show)

        guard options.live, let liveEngine else { return }
        let mic = try StereoAudio.loadChannel(StereoAudio.micChannel, from: audio, maxSeconds: limit)
        let system = try StereoAudio.loadChannel(StereoAudio.systemChannel, from: audio, maxSeconds: limit)

        for (name, commit) in [("old sliding", false), ("new commit", true)] where commit || !options.skipOld {
            let label = commit ? "new h\(Int(options.hop)) c\(options.context) \(options.liveModel.replacingOccurrences(of: "whisper-", with: ""))" : name
            let micRun = await replayLive(engine: liveEngine, samples: mic, channel: .mic, speaker: .you, commit: commit, prompt: options.prompt, hop: options.hop, context: options.context)
            let systemRun = await replayLive(engine: liveEngine, samples: system, channel: .system, speaker: .others, commit: commit, prompt: options.prompt, hop: options.hop, context: options.context)
            let echo = clean(micRun.segments + systemRun.segments)
            save(label.replacingOccurrences(of: " ", with: "-"), echo)
            score(label: label, candidate: echo, reference: reference.segments, limit: limit, speech: speech, show: options.show)
            let micRTF = micRun.wall / max(reference.audioSeconds, 1), sysRTF = systemRun.wall / max(reference.audioSeconds, 1)
            print(String(format: "   %@  decode time as a share of audio length: You %.2f, Others %.2f (both must stay under 1.0 together)",
                         label.padding(toLength: 14, withPad: " ", startingAt: 0), micRTF, sysRTF))
        }
    } catch {
        print("• \(name): failed — \(error.localizedDescription)")
    }
}

let options = parse()
guard !options.folders.isEmpty else {
    print("usage: vm-transcribe-eval <meeting-folder>... [--model id] [--live] [--live-model id] [--minutes n] [--prompt text] [--show n] [--save dir]")
    exit(2)
}

guard let referenceEngine = await load(options.model) else { exit(1) }
var liveEngine: WhisperKitEngine?
if options.live {
    liveEngine = options.liveModel == options.model ? referenceEngine : await load(options.liveModel)
    if liveEngine == nil { exit(1) }
}
for folder in options.folders {
    await evaluate(folder: folder, reference: referenceEngine, liveEngine: liveEngine, options: options)
}
