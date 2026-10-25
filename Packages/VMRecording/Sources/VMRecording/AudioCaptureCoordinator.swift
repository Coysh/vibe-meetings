import AVFoundation
import CoreAudio
import VMCore

/// Concrete `AudioCaptureService` that wires together the mic capturer, the system tap,
/// the dual-channel m4a writer, and a level meter, exposing the four async streams the
/// rest of the app consumes.
public actor AudioCaptureCoordinator: AudioCaptureService {
    private nonisolated let mic = MicrophoneCapturer()
    private nonisolated let system = SystemAudioCapturer()

    private nonisolated let stateContinuation: AsyncStream<CaptureState>.Continuation
    private nonisolated let levelContinuation: AsyncStream<LevelSnapshot>.Continuation
    private nonisolated let micPCMContinuation: AsyncStream<PCMChunk>.Continuation
    private nonisolated let systemPCMContinuation: AsyncStream<PCMChunk>.Continuation

    public nonisolated let state: AsyncStream<CaptureState>
    public nonisolated let levels: AsyncStream<LevelSnapshot>
    public nonisolated let micPCM: AsyncStream<PCMChunk>
    public nonisolated let systemPCM: AsyncStream<PCMChunk>

    private var writer: DualChannelM4AWriter?
    private var pumpTasks: [Task<Void, Never>] = []
    private var droppedFrames: Int = 0
    private var startEpoch: TimeInterval = 0
    private var isRunning = false

    /// Writer reference accessible from detached tasks without actor hop.
    private nonisolated let _writerBox = WriterBox()

    /// Echo-cancellation state shared with the pump tasks (no actor hop).
    private nonisolated let _echo = EchoBox()
    private var aecOutputTask: Task<Void, Never>?

    public init() {
        let (sStream, sCont) = AsyncStream.makeStream(of: CaptureState.self)
        self.state = sStream
        self.stateContinuation = sCont

        let (lStream, lCont) = AsyncStream.makeStream(of: LevelSnapshot.self)
        self.levels = lStream
        self.levelContinuation = lCont

        let (mStream, mCont) = AsyncStream.makeStream(of: PCMChunk.self, bufferingPolicy: .unbounded)
        self.micPCM = mStream
        self.micPCMContinuation = mCont

        let (yStream, yCont) = AsyncStream.makeStream(of: PCMChunk.self, bufferingPolicy: .unbounded)
        self.systemPCM = yStream
        self.systemPCMContinuation = yCont
    }

    // MARK: - Echo cancellation / capture status

    /// Configure acoustic echo cancellation of the transcription mic feed. Call
    /// before `start`. Only takes effect when the system-audio tap starts (it is
    /// the far-end reference); otherwise the mic is passed through untouched.
    /// - Parameter debugWAVURL: if set, the cancelled mic is also written there
    ///   (16 kHz mono) for listening/diagnostics. Never used for transcription.
    public func configureEchoCancellation(enabled: Bool, debugWAVURL: URL? = nil) {
        _echo.enabled = enabled
        _echo.debugWAVURL = debugWAVURL
    }

    /// Live echo-cancellation diagnostics; `nil` when cancellation isn't running.
    public nonisolated var echoStats: EchoCancellationStats? { _echo.pipeline?.stats }

    /// Whether the system-audio tap (the "Others" channel) is capturing. `false`
    /// before `start`, and after a start where the tap failed (usually the
    /// System Audio Recording permission being denied).
    public nonisolated var systemAudioAvailable: Bool { _echo.systemAvailable }

    /// Why the system-audio tap is unavailable, if it failed to start.
    public nonisolated var systemAudioError: String? { _echo.systemError }

    public func start(writingAudioTo url: URL?, micDeviceID: AudioDeviceID? = nil) async throws {
        guard !isRunning else { throw AudioCaptureError.alreadyRunning }
        stateContinuation.yield(.preparing)

        if let url {
            let w = try DualChannelM4AWriter(url: url)
            self.writer = w
            self._writerBox.writer = w
            w.start()
        }

        startEpoch = MicrophoneCapturer.nowHostSeconds()
        _echo.micDeviceID = micDeviceID

        print("[Coordinator] starting mic, deviceID=\(String(describing: micDeviceID))")
        do {
            try mic.start(epoch: startEpoch, deviceID: micDeviceID)
        } catch {
            stateContinuation.yield(.error("mic: \(error.localizedDescription)"))
            throw error
        }

        // System audio tap is best-effort — the mic alone is sufficient for
        // transcription. If the tap fails (no Screen Recording permission,
        // unsupported hardware, etc.) we log and continue with mic only.
        do {
            try system.start(epoch: startEpoch)
            _echo.systemAvailable = true
            _echo.systemError = nil
            print("[Coordinator] system audio tap started")
        } catch {
            _echo.systemAvailable = false
            _echo.systemError = error.localizedDescription
            print("[Coordinator] ⚠️ System audio tap unavailable: \(error.localizedDescription)")
            print("[Coordinator] The 'Others' channel won't capture. Grant System Audio Recording permission to enable.")
        }

        startPumps()
        isRunning = true
        stateContinuation.yield(.recording)
    }

    /// Switch the microphone device mid-recording without interrupting streams.
    public func switchMicDevice(to deviceID: AudioDeviceID?) throws {
        guard isRunning else { return }
        try mic.switchDevice(to: deviceID)
        _echo.micDeviceID = deviceID
        _echo.pipeline?.resetForDeviceChange()
        _echo.pipeline?.setDeviceNames(mic: Self.micName(for: deviceID), output: AudioDeviceEnumerator.defaultOutputDeviceName())
    }

    private static func micName(for deviceID: AudioDeviceID?) -> String? {
        let id = deviceID ?? AudioDeviceEnumerator.defaultInputDeviceID()
        return id.flatMap { AudioDeviceEnumerator.name(for: $0) }
    }

    public func pause() async {
        guard isRunning else { return }
        // We don't actually pause the engines; we simply drop their forwarded chunks.
        // True pause requires teardown + restart; meeting use-case favours continuous capture.
        stateContinuation.yield(.paused)
    }

    public func resume() async {
        guard isRunning else { return }
        stateContinuation.yield(.recording)
    }

    public func stop() async throws -> CaptureResult {
        guard isRunning else { throw AudioCaptureError.notRunning }
        stateContinuation.yield(.stopping)

        mic.stop()
        system.stop()
        for t in pumpTasks { t.cancel() }
        pumpTasks.removeAll()

        // Flush the echo canceller: it emits any mic audio it was still holding
        // into the transcription stream, then ends its output, which lets the
        // forwarding task finish — all before we close `micPCM` below.
        if let aec = _echo.pipeline {
            aec.finish()
            await aecOutputTask?.value
            aecOutputTask = nil
        }

        var finalAudioURL: URL? = nil
        if let writer {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.stop { url in
                    finalAudioURL = url
                    cont.resume()
                }
            }
        }
        let duration = MicrophoneCapturer.nowHostSeconds() - startEpoch

        micPCMContinuation.finish()
        systemPCMContinuation.finish()
        levelContinuation.finish()
        stateContinuation.yield(.idle)

        isRunning = false
        return CaptureResult(audioFileURL: finalAudioURL, duration: duration, droppedFrames: droppedFrames)
    }

    // MARK: - private

    private func startPumps() {
        // Capture nonisolated references so pump tasks never need to hop
        // back onto the actor — that was causing serial starvation.
        let micPCMCont = micPCMContinuation
        let sysPCMCont = systemPCMContinuation
        let levelCont = levelContinuation
        let writerBox = _writerBox
        let micSource = mic
        let sysSource = system
        let levelTracker = LevelTracker()

        // Acoustic echo cancellation needs the far end as a reference, so it only
        // runs when the system tap is up.
        var aec: EchoCancellationPipeline?
        if _echo.enabled && _echo.systemAvailable {
            let pipe = EchoCancellationPipeline()
            pipe.setDeviceNames(mic: Self.micName(for: _echo.micDeviceID), output: AudioDeviceEnumerator.defaultOutputDeviceName())
            _echo.pipeline = pipe
            aec = pipe
            let debugWriter = _echo.debugWAVURL.flatMap { try? CrashSafeWAVWriter(url: $0, sampleRate: 16_000, channels: 1) }
            // Cancelled mic → transcription stream (and the optional debug WAV).
            aecOutputTask = Task.detached {
                for await chunk in pipe.output {
                    micPCMCont.yield(chunk)
                    debugWriter?.append(chunk.samples.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) })
                }
                debugWriter?.finalize()
            }
        } else {
            _echo.pipeline = nil
        }
        let echoPipeline = aec

        // Capture the streams themselves so they stay alive for the pump
        // task's entire lifetime (not just the duration of makeAsyncIterator).
        let micPCMStream = micSource.pcm
        let micBufStream = micSource.buffers
        let sysPCMStream = sysSource.pcm
        let sysBufStream = sysSource.buffers

        // Mic PCM → engine stream + levels (no actor hop).
        pumpTasks.append(Task.detached {
            var count = 0
            print("[Coordinator] mic PCM pump started, waiting for chunks...")
            for await chunk in micPCMStream {
                // Levels and the on-disk recording always use the raw mic; only
                // what the transcriber hears is echo-cancelled.
                if let echoPipeline { echoPipeline.pushMic(chunk) } else { micPCMCont.yield(chunk) }
                count += 1
                if count <= 3 || count % 50 == 0 {
                    print("[Coordinator] mic pump chunk #\(count), \(chunk.samples.count) samples")
                }
                let level = rms(chunk.samples)
                levelTracker.update(mic: level)
                levelCont.yield(levelTracker.snapshot(at: chunk.timestamp))
            }
            let cancelled = Task.isCancelled
            print("[Coordinator] mic PCM pump ended after \(count) chunks (cancelled=\(cancelled))")
            if echoPipeline == nil { micPCMCont.finish() }   // with AEC, its output task owns the end of the stream
            withExtendedLifetime(micSource) {}  // keep mic alive until pump ends
        })
        // Mic raw buffers → writer (no actor hop).
        pumpTasks.append(Task.detached {
            var count = 0
            for await buf in micBufStream {
                writerBox.writer?.appendMic(buf)
                count += 1
            }
            print("[Coordinator] mic buffer pump ended after \(count) buffers")
            withExtendedLifetime(micSource) {}
        })

        // System PCM → engine stream + levels (no actor hop).
        pumpTasks.append(Task.detached {
            for await chunk in sysPCMStream {
                echoPipeline?.pushReference(chunk)
                sysPCMCont.yield(chunk)
                let level = rms(chunk.samples)
                levelTracker.update(system: level)
                levelCont.yield(levelTracker.snapshot(at: chunk.timestamp))
            }
        })
        // System raw buffers → writer (no actor hop).
        pumpTasks.append(Task.detached {
            for await buf in sysBufStream {
                writerBox.writer?.appendSystem(buf)
            }
        })
    }
}

private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return -120 }
    var sum: Float = 0
    for s in samples { sum += s * s }
    let mean = sum / Float(samples.count)
    let rmsValue = sqrtf(max(mean, 1e-10))
    return 20 * log10f(rmsValue)
}

/// Echo-cancellation configuration and live state, readable from any context.
private final class EchoBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = true
    private var _debugWAVURL: URL?
    private var _pipeline: EchoCancellationPipeline?
    private var _systemAvailable = false
    private var _systemError: String?
    private var _micDeviceID: AudioDeviceID?

    var enabled: Bool { get { lock.withLock { _enabled } } set { lock.withLock { _enabled = newValue } } }
    var micDeviceID: AudioDeviceID? { get { lock.withLock { _micDeviceID } } set { lock.withLock { _micDeviceID = newValue } } }
    var debugWAVURL: URL? { get { lock.withLock { _debugWAVURL } } set { lock.withLock { _debugWAVURL = newValue } } }
    var pipeline: EchoCancellationPipeline? { get { lock.withLock { _pipeline } } set { lock.withLock { _pipeline = newValue } } }
    var systemAvailable: Bool { get { lock.withLock { _systemAvailable } } set { lock.withLock { _systemAvailable = newValue } } }
    var systemError: String? { get { lock.withLock { _systemError } } set { lock.withLock { _systemError = newValue } } }
}

/// Non-actor box so pump tasks can access the writer without an actor hop.
private final class WriterBox: @unchecked Sendable {
    var writer: DualChannelM4AWriter?
}

/// Thread-safe level tracker so pump tasks can update levels without an actor hop.
private final class LevelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var micLevel: Float = -120
    private var sysLevel: Float = -120

    func update(mic: Float? = nil, system: Float? = nil) {
        lock.lock()
        if let m = mic { micLevel = m }
        if let s = system { sysLevel = s }
        lock.unlock()
    }

    func snapshot(at ts: TimeInterval) -> LevelSnapshot {
        lock.lock()
        let snap = LevelSnapshot(mic: micLevel, system: sysLevel, timestamp: ts)
        lock.unlock()
        return snap
    }
}

