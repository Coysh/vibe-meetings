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
            print("[Coordinator] system audio tap started")
        } catch {
            print("[Coordinator] ⚠️ System audio tap unavailable: \(error.localizedDescription)")
            print("[Coordinator] The 'Others' channel won't capture. Grant Screen Recording permission to enable.")
        }

        startPumps()
        isRunning = true
        stateContinuation.yield(.recording)
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
                micPCMCont.yield(chunk)
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
            micPCMCont.finish()
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

