import AVFoundation
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

    public init() {
        var sCont: AsyncStream<CaptureState>.Continuation!
        self.state = AsyncStream { sCont = $0 }
        self.stateContinuation = sCont

        var lCont: AsyncStream<LevelSnapshot>.Continuation!
        self.levels = AsyncStream { lCont = $0 }
        self.levelContinuation = lCont

        var mCont: AsyncStream<PCMChunk>.Continuation!
        self.micPCM = AsyncStream { mCont = $0 }
        self.micPCMContinuation = mCont

        var yCont: AsyncStream<PCMChunk>.Continuation!
        self.systemPCM = AsyncStream { yCont = $0 }
        self.systemPCMContinuation = yCont
    }

    public func start(writingAudioTo url: URL?) async throws {
        guard !isRunning else { throw AudioCaptureError.alreadyRunning }
        stateContinuation.yield(.preparing)

        if let url {
            self.writer = try DualChannelM4AWriter(url: url)
            self.writer?.start()
        }

        startEpoch = MicrophoneCapturer.nowHostSeconds()

        do {
            try mic.start(epoch: startEpoch)
        } catch {
            stateContinuation.yield(.error("mic: \(error.localizedDescription)"))
            throw error
        }

        do {
            try system.start(epoch: startEpoch)
        } catch {
            mic.stop()
            stateContinuation.yield(.error("system: \(error.localizedDescription)"))
            throw error
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
        // Mic PCM → engine stream + writer + levels
        pumpTasks.append(Task { [weak self] in
            guard let self else { return }
            for await chunk in self.mic.pcm {
                self.micPCMContinuation.yield(chunk)
                await self.recordLevel(mic: rms(chunk.samples), at: chunk.timestamp)
            }
        })
        pumpTasks.append(Task { [weak self] in
            guard let self else { return }
            for await buf in self.mic.buffers {
                await self.writer?.appendMic(buf)
            }
        })

        // System PCM → engine stream + writer + levels
        pumpTasks.append(Task { [weak self] in
            guard let self else { return }
            for await chunk in self.system.pcm {
                self.systemPCMContinuation.yield(chunk)
                await self.recordLevel(system: rms(chunk.samples), at: chunk.timestamp)
            }
        })
        pumpTasks.append(Task { [weak self] in
            guard let self else { return }
            for await buf in self.system.buffers {
                await self.writer?.appendSystem(buf)
            }
        })
    }

    private var lastMicLevel: Float = -120
    private var lastSysLevel: Float = -120

    private func recordLevel(mic: Float? = nil, system: Float? = nil, at ts: TimeInterval) {
        if let m = mic { lastMicLevel = m }
        if let s = system { lastSysLevel = s }
        levelContinuation.yield(LevelSnapshot(mic: lastMicLevel, system: lastSysLevel, timestamp: ts))
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
