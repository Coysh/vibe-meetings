import AVFoundation
import Foundation
import VMCore
import VMRecording

// vm-aec-eval — run the echo canceller over saved recordings and report how
// much echo it removes and whether it harms the user's own speech.
//
//   swift run -c release vm-aec-eval ~/MeetingNotes --out <dir> [--limit N] [--minutes M]
//                                   [--only substring] [--frame 256] [--tail 4096] [--no-residual]
//
// Read-only on the meetings folder. Each meeting's audio.m4a is stereo
// (L = mic, R = system tap). Segments (segments.json, from the live Whisper
// pass) label which stretches are far-end-only vs. the user talking.

struct Options {
    var root = NSString(string: "~/MeetingNotes").expandingTildeInPath
    var out = FileManager.default.currentDirectoryPath + "/aec-eval-out"
    var limit = 6
    var minutes = 15.0
    var only: String?
    var config = EchoCancellationPipeline.Configuration()
    var writeWAV = true
    var timeline = false
}

func parseArgs() -> Options {
    var o = Options()
    var a = Array(CommandLine.arguments.dropFirst())
    if let first = a.first, !first.hasPrefix("--") { o.root = NSString(string: first).expandingTildeInPath; a.removeFirst() }
    var i = 0
    while i < a.count {
        switch a[i] {
        case "--out": i += 1; o.out = a[i]
        case "--limit": i += 1; o.limit = Int(a[i]) ?? o.limit
        case "--minutes": i += 1; o.minutes = Double(a[i]) ?? o.minutes
        case "--only": i += 1; o.only = a[i]
        case "--frame": i += 1; o.config.frameSize = Int(a[i]) ?? 256
        case "--tail": i += 1; o.config.tailLength = Int(a[i]) ?? 4096
        case "--no-residual": o.config.residualSuppression = false
        case "--no-wav": o.writeWAV = false
        case "--timeline": o.timeline = true
        default: break
        }
        i += 1
    }
    return o
}

/// Decode a stereo file into two 16 kHz mono channels (first `maxSeconds`).
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

func rms(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return 0 }
    var e = 0.0
    for v in x { e += Double(v) * Double(v) }
    return (e / Double(x.count)).squareRoot()
}
func db(_ r: Double) -> Double { 20 * log10(max(r, 1e-9)) }

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

func evaluate(meeting dir: URL, opts: Options) async {
    let name = dir.lastPathComponent
    let audio = dir.appendingPathComponent("audio.m4a")
    guard let segData = FileManager.default.contents(atPath: dir.appendingPathComponent("segments.json").path),
          let segs = try? JSONDecoder().decode([TranscriptSegment].self, from: segData),
          segs.contains(where: { $0.channel == .system }) else { print("• \(name): skipped (no dual-channel segments)"); return }
    guard let (mic, ref) = try? loadChannels(audio, maxSeconds: opts.minutes * 60), mic.count > 16_000 * 30 else { print("• \(name): skipped (unreadable/short)"); return }
    let n = min(mic.count, ref.count)

    let started = Date()
    let pipe = EchoCancellationPipeline(configuration: opts.config)
    var i = 0, j = 0
    var timeline: [String] = []
    var nextProbe = 60.0
    // Deliver in time order, as the live capture would.
    while i < n || j < n {
        let tMic = i < n ? Double(min(i + 1365, n)) / 16_000 : .infinity
        let tRef = j < n ? Double(min(j + 160, n)) / 16_000 : .infinity
        if opts.timeline, min(tMic, tRef) >= nextProbe {
            pipe.waitUntilIdle()
            let st = pipe.stats
            timeline.append(String(format: "      t=%4.0fs  delay=%7.1f ms  conf=%5.1f  erle(10s median)=%@  commits=%d resets=%d", nextProbe, st.delayMs ?? .nan, st.delayConfidence, st.erleDB.map { String(format: "%.1f dB", $0) } ?? "-", st.delayCommits, st.filterResets))
            nextProbe += 60
        }
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
    let wall = Date().timeIntervalSince(started)
    let stats = pipe.stats

    // Label 20 ms blocks.
    let kept = Set(EchoDedup.suppress(segs).map(\.id))
    let userSegs = segs.filter { $0.channel == .mic && kept.contains($0.id) }
    func inUserSpeech(_ t: Double) -> Bool { userSegs.contains { $0.start <= t && t <= $0.end } }
    let block = 320
    var far = (mic: 0.0, out: 0.0, n: 0), farLate = (mic: 0.0, out: 0.0, n: 0)
    var user = (mic: 0.0, out: 0.0, n: 0), dt = (mic: 0.0, out: 0.0, n: 0)
    var loud = (mic: 0.0, out: 0.0, n: 0)       // far-end only AND the mic is clearly hearing it
    var b = 0
    while (b + 1) * block <= min(out.count, n) {
        let r = b * block..<(b + 1) * block
        let t = Double(b * block) / 16_000
        let refDB = db(rms(ref[r])), speaking = inUserSpeech(t)
        let me = Double(mic[r].reduce(0) { $0 + $1 * $1 }), oe = Double(out[r].reduce(0) { $0 + $1 * $1 })
        if refDB > -45 && !speaking {
            far.mic += me; far.out += oe; far.n += 1
            if t > 15 { farLate.mic += me; farLate.out += oe; farLate.n += 1
                if db(rms(mic[r])) > -42 { loud.mic += me; loud.out += oe; loud.n += 1 } }
        }
        else if refDB < -50 && speaking { user.mic += me; user.out += oe; user.n += 1 }
        else if refDB > -45 && speaking { dt.mic += me; dt.out += oe; dt.n += 1 }
        b += 1
    }
    func gain(_ x: (mic: Double, out: Double, n: Int)) -> String {
        x.n < 25 ? "   n/a (\(x.n) blocks)" : String(format: "%6.1f dB (%d blocks)", 10 * log10(max(x.mic, 1e-12) / max(x.out, 1e-12)), x.n)
    }
    print("• \(name)  [\(Int(Double(n) / 16_000 / 60)) min, \(String(format: "%.0f", Double(n) / 16_000 / wall))× real time]")
    print("    mode=\(stats.mode.rawValue)  delay=\(stats.delayMs.map { String(format: "%.1f ms", $0) } ?? "none")  confidence=\(String(format: "%.1f", stats.delayConfidence))  drift=\(String(format: "%.0f", stats.driftPPM)) ppm  commits=\(stats.delayCommits) resets=\(stats.filterResets) underruns=\(stats.referenceUnderruns)")
    print("    echo removed, far-end only (after 15 s): \(gain(farLate))     overall: \(gain(far))")
    print("    …where echo clearly dominates the mic:   \(gain(loud))")
    print("    your own speech (far end silent):        \(gain(user))   ← want ≈ 0 dB")
    print("    both talking:                            \(gain(dt))")
    if opts.timeline { print("    delay timeline:"); timeline.forEach { print($0) } }
    if opts.writeWAV {
        let d = URL(fileURLWithPath: opts.out).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        writeWAV(Array(mic[0..<out.count]), to: d.appendingPathComponent("mic-raw.wav"))
        writeWAV(out, to: d.appendingPathComponent("mic-aec.wav"))
    }
}

let opts = parseArgs()
let fm = FileManager.default
var meetings: [URL] = []
if let en = fm.enumerator(at: URL(fileURLWithPath: opts.root), includingPropertiesForKeys: nil) {
    // (`allObjects`: DirectoryEnumerator can't be iterated from an async context.)
    for case let u as URL in en.allObjects where u.lastPathComponent == "audio.m4a" {
        let dir = u.deletingLastPathComponent()
        if let only = opts.only, !dir.lastPathComponent.contains(only) { continue }
        meetings.append(dir)
    }
}
meetings.sort { $0.lastPathComponent > $1.lastPathComponent }
print("Evaluating up to \(opts.limit) meetings (first \(Int(opts.minutes)) min each) from \(opts.root)\n")
var done = 0
for m in meetings where done < opts.limit {
    await evaluate(meeting: m, opts: opts)
    done += 1
}
