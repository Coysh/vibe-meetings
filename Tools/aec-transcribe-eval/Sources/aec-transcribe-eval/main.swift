import AVFoundation
import Foundation
import VMCore
import VMRecording
import VMTranscription

// aec-transcribe-eval — does acoustic echo cancellation of the mic channel
// reduce echoed lines in a Whisper transcript, without losing the user's speech?
//
//   aec-transcribe-eval [--only <substring>]... [--limit N] [--minutes M] [--model <id>]
//
// For each meeting: decode mic (L) + system (R) to 16 kHz mono, run the mic through
// EchoCancellationPipeline, transcribe micRaw / micAEC / sys with WhisperKit and
// compare the raw vs AEC mic transcripts after EchoDedup.
// Read-only on ~/MeetingNotes; all output goes to the scratch dir.

let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-timcoysh-Developer-vibe-meetings/febb38f3-ef67-459e-b71c-07a370aa2dad/scratchpad/aec-transcribe")
let fm = FileManager.default

struct Options {
    var root = NSString(string: "~/MeetingNotes").expandingTildeInPath
    var only: [String] = []
    var limit = 3
    var minutes = 8.0
    var model: String?
}

func parseArgs() -> Options {
    var o = Options()
    let a = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < a.count {
        switch a[i] {
        case "--only": i += 1; o.only.append(a[i])
        case "--limit": i += 1; o.limit = Int(a[i]) ?? o.limit
        case "--minutes": i += 1; o.minutes = Double(a[i]) ?? o.minutes
        case "--model": i += 1; o.model = a[i]
        default: break
        }
        i += 1
    }
    return o
}

func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - Audio (copied from vm-aec-eval)

func loadChannels(_ url: URL, maxSeconds: Double) throws -> (mic: [Float], ref: [Float]) {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.channelCount == 2 else { throw NSError(domain: "eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "not stereo"]) }
    let sr = file.processingFormat.sampleRate
    let maxFrames = AVAudioFramePosition(maxSeconds * sr)
    let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
    let micConv = AudioFormatConverter(), refConv = AudioFormatConverter()
    var mic: [Float] = [], ref: [Float] = []
    let chunk: AVAudioFrameCount = 48_000
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return ([], []) }
    while file.framePosition < min(file.length, maxFrames) {
        try file.read(into: buf, frameCount: chunk)
        if buf.frameLength == 0 { break }
        guard let ch = buf.floatChannelData else { break }
        for (idx, conv) in [(0, micConv), (1, refConv)] {
            let m = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: buf.frameLength)!
            m.frameLength = buf.frameLength
            m.floatChannelData![0].update(from: ch[idx], count: Int(buf.frameLength))
            let s = try conv.convert(m)
            if idx == 0 { mic += s } else { ref += s }
        }
    }
    return (mic, ref)
}

func writeWAV(_ samples: [Float], to url: URL) {
    var data = Data()
    func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
    let n = samples.count
    data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + n * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
    put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(16_000)); put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
    data.append(contentsOf: "data".utf8); put(UInt32(n * 2))
    for s in samples { put(Int16(max(-32768, min(32767, (s * 32768).rounded())))) }
    try? data.write(to: url)
}

func runAEC(mic: [Float], ref: [Float]) async -> (out: [Float], stats: EchoCancellationStats) {
    let n = min(mic.count, ref.count)
    let pipe = EchoCancellationPipeline(configuration: .init())
    var i = 0, j = 0
    while i < n || j < n {
        let tMic = i < n ? Double(min(i + 1365, n)) / 16_000 : .infinity
        let tRef = j < n ? Double(min(j + 160, n)) / 16_000 : .infinity
        if tMic <= tRef {
            let e = min(i + 1365, n); pipe.pushMic(PCMChunk(samples: Array(mic[i..<e]), timestamp: Double(i) / 16_000)); i = e
        } else {
            let e = min(j + 160, n); pipe.pushReference(PCMChunk(samples: Array(ref[j..<e]), timestamp: Double(j) / 16_000)); j = e
        }
    }
    pipe.finish()
    var out: [Float] = []
    out.reserveCapacity(n)
    for await c in pipe.output { out += c.samples }
    return (out, pipe.stats)
}

// MARK: - Transcription

func relabel(_ segs: [TranscriptSegment], as channel: AudioChannel) -> [TranscriptSegment] {
    segs.map { TranscriptSegment(speakerId: channel == .mic ? "you" : "others", channel: channel, start: $0.start, end: $0.end, text: $0.text, confidence: $0.confidence) }
}

/// Transcribe a WAV, caching the result next to it so reruns are cheap.
func transcribe(_ engine: WhisperKitEngine, wav: URL, channel: AudioChannel) async throws -> [TranscriptSegment] {
    let cache = wav.deletingPathExtension().appendingPathExtension("segments.json")
    if let d = fm.contents(atPath: cache.path), let s = try? JSONDecoder().decode([TranscriptSegment].self, from: d) { return relabel(s, as: channel) }
    let t0 = Date()
    let raw = try await engine.transcribeFile(
        at: wav,
        options: TranscriptionOptions(language: "en", enableWordTimestamps: false))
    log(String(format: "    transcribed %@ in %.0fs (%d segments)", wav.lastPathComponent, Date().timeIntervalSince(t0), raw.count))
    try JSONEncoder().encode(raw).write(to: cache)
    return relabel(raw, as: channel)
}

// MARK: - Metrics

struct Metrics {
    var nMic = 0, wordsMic = 0
    var nKept = 0, wordsKept = 0
    var suspicious = 0
    var examples: [(mic: String, sys: String)] = []
}

func words(_ s: String) -> Int { TextSimilarity.tokens(s).count }

func systemText(near seg: TranscriptSegment, sys: [TranscriptSegment], window: Double = 4) -> [String] {
    sys.filter { $0.end >= seg.start - window && $0.start <= seg.end + window }
        .sorted { $0.start < $1.start }
        .flatMap { TextSimilarity.tokens($0.text) }
}

func measure(mic: [TranscriptSegment], sys: [TranscriptSegment]) -> Metrics {
    var m = Metrics()
    m.nMic = mic.count
    m.wordsMic = mic.reduce(0) { $0 + words($1.text) }
    let kept = EchoDedup.suppress(mic + sys, config: .default).filter { $0.channel == .mic }
    m.nKept = kept.count
    m.wordsKept = kept.reduce(0) { $0 + words($1.text) }
    for seg in kept {
        let mt = TextSimilarity.tokens(seg.text)
        guard mt.count >= 4 else { continue }
        let st = systemText(near: seg, sys: sys)
        guard !st.isEmpty else { continue }
        let align = TextSimilarity.lcsAlignment(micCount: mt.count, sysCount: st.count) { i, j in
            TextSimilarity.fuzzyEqual(mt[i], st[j])
        }
        let coverage = Double(align.compactMap { $0 }.count) / Double(mt.count)
        if coverage >= 0.5 {
            m.suspicious += 1
            m.examples.append((String(format: "[%.0fs] ", seg.start) + seg.text, st.joined(separator: " ")))
        }
    }
    return m
}

// MARK: - Main

struct Row {
    var name: String
    var raw: Metrics, aec: Metrics
    var stats: EchoCancellationStats
    var sysWords: Int
}

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }

func evaluate(meeting dir: URL, opts: Options, engine: WhisperKitEngine) async -> Row? {
    let name = dir.lastPathComponent
    guard let segData = fm.contents(atPath: dir.appendingPathComponent("segments.json").path),
          let segs = try? JSONDecoder().decode([TranscriptSegment].self, from: segData),
          segs.contains(where: { $0.channel == .system }) else { log("• \(name): skipped (no system segments)"); return nil }
    log("• \(name): decoding + AEC")
    guard let (mic, ref) = try? loadChannels(dir.appendingPathComponent("audio.m4a"), maxSeconds: opts.minutes * 60),
          mic.count > 16_000 * 30 else { log("  skipped (unreadable/short)"); return nil }
    let n = min(mic.count, ref.count)
    let t0 = Date()
    let (aec, stats) = await runAEC(mic: mic, ref: ref)
    log(String(format: "  AEC done in %.0fs: mode=%@ delay=%@ conf=%.1f erle=%@", Date().timeIntervalSince(t0), stats.mode.rawValue,
               stats.delayMs.map { String(format: "%.0fms", $0) } ?? "-", stats.delayConfidence, stats.erleDB.map { String(format: "%.1fdB", $0) } ?? "-"))

    let tag = "\(name)-\(Int(opts.minutes))min"
    let d = scratch.appendingPathComponent(tag)
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    let rawURL = d.appendingPathComponent("micRaw.wav"), aecURL = d.appendingPathComponent("micAEC.wav"), sysURL = d.appendingPathComponent("sys.wav")
    writeWAV(Array(mic[0..<n]), to: rawURL)
    writeWAV(Array(aec[0..<min(aec.count, n)]), to: aecURL)
    writeWAV(Array(ref[0..<n]), to: sysURL)

    do {
        let sys = try await transcribe(engine, wav: sysURL, channel: .system)
        let raw = try await transcribe(engine, wav: rawURL, channel: .mic)
        let cleaned = try await transcribe(engine, wav: aecURL, channel: .mic)
        let r = measure(mic: raw, sys: sys), a = measure(mic: cleaned, sys: sys)
        // Dump a merged, time-ordered view (kept mic lines for each variant + system) for eyeballing.
        func dump(_ label: String, _ mic: [TranscriptSegment]) -> [(Double, String)] {
            let kept = Set(EchoDedup.suppress(mic + sys, config: .default).filter { $0.channel == .mic }.map(\.id))
            return mic.map { ($0.start, String(format: "%7.1f %@ %@ %@", $0.start, label, kept.contains($0.id) ? "KEPT   " : "dropped", $0.text)) }
        }
        let lines = dump("RAW", raw) + dump("AEC", cleaned) + sys.map { ($0.start, String(format: "%7.1f SYS %@", $0.start, $0.text)) }
        try? lines.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n").write(to: d.appendingPathComponent("timeline.txt"), atomically: true, encoding: .utf8)
        log("  raw: \(r.nMic) segs/\(r.wordsMic)w -> kept \(r.nKept)/\(r.wordsKept)w susp \(r.suspicious)   aec: \(a.nMic) segs/\(a.wordsMic)w -> kept \(a.nKept)/\(a.wordsKept)w susp \(a.suspicious)")
        return Row(name: name, raw: r, aec: a, stats: stats, sysWords: sys.reduce(0) { $0 + words($1.text) })
    } catch {
        log("  transcription failed: \(error)")
        return nil
    }
}

let opts = parseArgs()
var meetings: [URL] = []
if let en = fm.enumerator(at: URL(fileURLWithPath: opts.root), includingPropertiesForKeys: nil) {
    for case let u as URL in en.allObjects where u.lastPathComponent == "audio.m4a" {
        let dir = u.deletingLastPathComponent()
        if !opts.only.isEmpty && !opts.only.contains(where: { dir.lastPathComponent.contains($0) }) { continue }
        meetings.append(dir)
    }
}
meetings.sort { $0.lastPathComponent > $1.lastPathComponent }

// Pick an already-downloaded model; never download.
let engine = WhisperKitEngine()
let downloaded = ModelCatalog.entries(for: WhisperKitEngine.kind).filter { ModelCatalog.isDownloaded($0) }
log("Downloaded WhisperKit models: \(downloaded.map(\.id))")
let preference = ["whisper-base", "whisper-small", "whisper-medium", "whisper-large-v3"]
let modelId = opts.model ?? preference.first { id in downloaded.contains { $0.id == id } }
guard let modelId, downloaded.contains(where: { $0.id == modelId }) else {
    print("No suitable downloaded Whisper model (downloaded: \(downloaded.map(\.id))). Not downloading. Stopping.")
    exit(1)
}
log("Loading model \(modelId) …")
do { try await engine.loadModel(id: modelId, progress: { _ in }) } catch { print("model load failed: \(error)"); exit(1) }

var rows: [Row] = []
var done = 0
for m in meetings where done < opts.limit {
    if let r = await evaluate(meeting: m, opts: opts, engine: engine) { rows.append(r); done += 1 }
}

// MARK: - Report

print("\nmodel=\(modelId)  minutes=\(Int(opts.minutes))  meetings=\(rows.count)\n")
print("AEC stats")
for r in rows {
    let s = r.stats
    print("  \(r.name)\n    mode=\(s.mode.rawValue) delayMs=\(s.delayMs.map { String(format: "%.1f", $0) } ?? "-") conf=\(String(format: "%.1f", s.delayConfidence)) erleDB=\(s.erleDB.map { String(format: "%.1f", $0) } ?? "-") active=\(Int(s.activeSeconds))s bypass=\(Int(s.bypassSeconds))s")
}
print("\n                                   | nMic raw/aec | nKept raw/aec | wordsMic raw/aec | wordsKept raw/aec (aec%) | suspicious raw/aec | flag")
var tot = (nm: (0, 0), nk: (0, 0), wm: (0, 0), wk: (0, 0), su: (0, 0))
for r in rows {
    let lost = Double(r.aec.wordsKept) < 0.85 * Double(r.raw.wordsKept)
    // "didn't drop correspondingly": suspicious fell by less than the fraction of kept words lost.
    let keptLoss = r.raw.wordsKept == 0 ? 0 : 1 - Double(r.aec.wordsKept) / Double(r.raw.wordsKept)
    let suspDrop = r.raw.suspicious == 0 ? 0 : 1 - Double(r.aec.suspicious) / Double(r.raw.suspicious)
    let flag = lost && suspDrop < keptLoss ? "POSSIBLE SPEECH LOSS" : "-"
    let label = String(r.name.prefix(34)).padding(toLength: 34, withPad: " ", startingAt: 0)
    print("\(label) | \(r.raw.nMic)/\(r.aec.nMic) | \(r.raw.nKept)/\(r.aec.nKept) | \(r.raw.wordsMic)/\(r.aec.wordsMic) | \(r.raw.wordsKept)/\(r.aec.wordsKept) (\(pct(r.aec.wordsKept, r.raw.wordsKept))) | \(r.raw.suspicious)/\(r.aec.suspicious) | \(flag)")
    tot.nm.0 += r.raw.nMic; tot.nm.1 += r.aec.nMic; tot.nk.0 += r.raw.nKept; tot.nk.1 += r.aec.nKept
    tot.wm.0 += r.raw.wordsMic; tot.wm.1 += r.aec.wordsMic; tot.wk.0 += r.raw.wordsKept; tot.wk.1 += r.aec.wordsKept
    tot.su.0 += r.raw.suspicious; tot.su.1 += r.aec.suspicious
}
print("\(String("TOTAL").padding(toLength: 34, withPad: " ", startingAt: 0)) | \(tot.nm.0)/\(tot.nm.1) | \(tot.nk.0)/\(tot.nk.1) | \(tot.wm.0)/\(tot.wm.1) | \(tot.wk.0)/\(tot.wk.1) (\(pct(tot.wk.1, tot.wk.0))) | \(tot.su.0)/\(tot.su.1)")
if !rows.isEmpty {
    let c = Double(rows.count)
    print(String(format: "MEAN per meeting: nMic %.0f/%.0f  nKept %.0f/%.0f  wordsKept %.0f/%.0f  suspicious %.1f/%.1f",
                 Double(tot.nm.0) / c, Double(tot.nm.1) / c, Double(tot.nk.0) / c, Double(tot.nk.1) / c,
                 Double(tot.wk.0) / c, Double(tot.wk.1) / c, Double(tot.su.0) / c, Double(tot.su.1) / c))
}

print("\nExample kept-suspicious lines (mic text vs nearby system text)")
for r in rows {
    for (label, m) in [("raw", r.raw), ("aec", r.aec)] where !m.examples.isEmpty {
        print("  \(r.name) [\(label)] \(m.suspicious) suspicious")
        for e in m.examples.prefix(5) { print("    MIC: \(e.mic)\n    SYS: \(String(e.sys.prefix(220)))") }
    }
}
