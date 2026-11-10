import AVFoundation
import CoreAudio
import VMCore

/// Captures mic audio with `AVAudioEngine`, emits `PCMChunk`s and raw audio
/// buffers (wrapped in `SendableAudioBuffer` so they can travel through the
/// `AsyncStream` under Swift 6 strict concurrency).
///
/// The engine's input runs through a Core Audio default-device aggregate, so
/// anything that changes the system's default *output* (Teams switching to its
/// loopback device when someone shares their screen, plugging in headphones…)
/// makes the engine stop and post `AVAudioEngineConfigurationChange`. Nothing
/// restarts it automatically, so the capturer does that itself, and also runs a
/// watchdog for the case where the engine stops without telling anyone.
public final class MicrophoneCapturer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = AudioFormatConverter()
    private let pcmContinuation: AsyncStream<PCMChunk>.Continuation
    private let bufferContinuation: AsyncStream<SendableAudioBuffer>.Continuation
    public let pcm: AsyncStream<PCMChunk>
    public let buffers: AsyncStream<SendableAudioBuffer>
    public private(set) var startEpoch: TimeInterval = 0

    /// Called after each successful automatic restart, with a short reason.
    /// Set before `start`.
    public var onRestart: (@Sendable (String) -> Void)?
    /// Called once per episode when the mic has delivered nothing for
    /// `unresponsiveAfter` seconds despite restart attempts.
    public var onUnresponsive: (@Sendable () -> Void)?

    /// Seconds without a buffer after which the watchdog restarts the engine.
    static let stallAfter: TimeInterval = 2
    /// Seconds without a buffer after which the user is told.
    static let unresponsiveAfter: TimeInterval = 10
    /// Wait this long after a configuration change before restarting, since
    /// the system often changes devices several times in quick succession.
    static let debounce: TimeInterval = 0.25

    // MARK: State

    private let lock = NSLock()
    private var requestedDeviceID: AudioDeviceID?   // nil = system default
    /// The requested device's stable UID. Numeric IDs can change when macOS
    /// re-enumerates a USB device, so restarts look the device up by UID.
    private var requestedDeviceUID: String?
    private var isCapturing = false
    private var lastBufferTime: TimeInterval = 0     // host seconds, last mic buffer seen
    private var lastRestartTime: TimeInterval = 0    // host seconds, last (re)start of the engine
    private var _restartCount = 0

    /// Serialises restarts and owns the debounce / retry / watchdog state below.
    private let restartQueue = DispatchQueue(label: "vibe.mic-restart")
    private var pendingRestart: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var reportedUnresponsive = false
    private var configObserver: NSObjectProtocol?

    /// Number of times the engine was restarted after a configuration change or stall.
    public var restartCount: Int { lock.withLock { _restartCount } }

    public init() {
        let (pStream, pCont) = AsyncStream.makeStream(of: PCMChunk.self, bufferingPolicy: .unbounded)
        self.pcm = pStream
        self.pcmContinuation = pCont

        let (bStream, bCont) = AsyncStream.makeStream(of: SendableAudioBuffer.self, bufferingPolicy: .unbounded)
        self.buffers = bStream
        self.bufferContinuation = bCont
    }

    deinit {
        print("[MicCapturer] DEINIT — MicrophoneCapturer is being deallocated!")
    }

    // MARK: Start / stop

    /// Start capturing from a specific device, or the system default if `nil`.
    public func start(epoch: TimeInterval, deviceID: AudioDeviceID? = nil) throws {
        startEpoch = epoch
        let uid = Self.uid(of: deviceID)
        lock.withLock {
            requestedDeviceID = deviceID
            requestedDeviceUID = uid
            lastBufferTime = Self.nowHostSeconds()
            lastRestartTime = lastBufferTime
        }
        try configureAndStart()
        print("[MicCapturer] engine started")

        lock.withLock { isCapturing = true }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.scheduleRestart(reason: "configuration change", after: Self.debounce, attempt: 0)
        }
        startWatchdog()
    }

    /// Switch the capture device mid-recording without tearing down the
    /// async streams.
    public func switchDevice(to deviceID: AudioDeviceID?) throws {
        guard lock.withLock({ isCapturing }) else { return }
        let uid = Self.uid(of: deviceID)
        lock.withLock {
            requestedDeviceID = deviceID
            requestedDeviceUID = uid
        }
        // Run on the restart queue so it can't interleave with an automatic
        // restart, and wait so errors reach the caller.
        var failure: Error?
        restartQueue.sync {
            pendingRestart?.cancel()
            pendingRestart = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            do {
                try configureAndStart()
                print("[MicCapturer] engine restarted after device switch")
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    public func stop() {
        // Stop reacting to configuration changes first so tearing the engine
        // down below can't schedule a restart.
        lock.withLock { isCapturing = false }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        restartQueue.sync {
            pendingRestart?.cancel()
            pendingRestart = nil
            watchdog?.cancel()
            watchdog = nil
        }
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        pcmContinuation.finish()
        bufferContinuation.finish()
    }

    private static func uid(of deviceID: AudioDeviceID?) -> String? {
        guard let deviceID else { return nil }
        return AudioDeviceEnumerator.inputDevices().first(where: { $0.id == deviceID })?.uid
    }

    // MARK: Engine configuration

    /// Point the input node at the requested device (falling back to the
    /// default if it has gone away), install the tap and start the engine.
    /// The engine must be stopped.
    private func configureAndStart() throws {
        let input = engine.inputNode
        let (requestedID, requestedUID) = lock.withLock { (requestedDeviceID, requestedDeviceUID) }
        var wanted = requestedID
        if requestedID != nil {
            let devices = AudioDeviceEnumerator.inputDevices()
            if let uid = requestedUID, let match = devices.first(where: { $0.uid == uid }) {
                if match.id != requestedID { print("[MicCapturer] device id changed \(requestedID!) -> \(match.id) (same UID)") }
                wanted = match.id
                lock.withLock { requestedDeviceID = match.id }
            } else if let id = requestedID, !devices.contains(where: { $0.id == id }) {
                print("[MicCapturer] device id=\(id) is gone; falling back to the system default input")
                wanted = nil
            }
        }

        if let deviceID = wanted, let audioUnit = input.audioUnit {
            var devID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                print("[MicCapturer] set input device id=\(deviceID)")
            } else {
                print("[MicCapturer] failed to set device \(deviceID): OSStatus \(status)")
            }
        } else {
            print("[MicCapturer] using system default input device")
        }

        let format = input.inputFormat(forBus: 0)
        print("[MicCapturer] format: \(format.sampleRate) Hz, \(format.channelCount) ch")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.audioEngineFailed("Input node reports zero sample rate; mic permission?")
        }

        input.removeTap(onBus: 0)
        var tapCount = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            tapCount += 1
            self.lock.withLock { self.lastBufferTime = Self.nowHostSeconds() }
            let hostTime: UInt64? = when.isHostTimeValid ? when.hostTime : nil
            let copy = buffer.copy() as! AVAudioPCMBuffer
            self.bufferContinuation.yield(SendableAudioBuffer(copy, hostTime: hostTime))
            do {
                let samples = try self.converter.convert(buffer)
                if !samples.isEmpty {
                    let ts = Self.hostTime(when.hostTime) - self.startEpoch
                    let result = self.pcmContinuation.yield(PCMChunk(samples: samples, timestamp: ts))

                    if tapCount <= 3 || tapCount % 100 == 0 {
                        let energy = samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)
                        print("[MicCapturer] tap #\(tapCount): \(samples.count) samples, rms=\(energy), yield=\(result)")
                    }
                    // Detect if the continuation has been prematurely terminated.
                    if case .terminated = result {
                        print("[MicCapturer] ⚠️ pcmContinuation.yield returned .terminated at tap #\(tapCount)!")
                    }
                } else if tapCount <= 3 {
                    print("[MicCapturer] tap #\(tapCount): converter returned empty samples")
                }
            } catch {
                print("[MicCapturer] conversion error at tap #\(tapCount): \(error)")
            }
        }

        engine.prepare()
        try engine.start()
    }

    // MARK: Automatic recovery

    /// Schedule a restart on `restartQueue`, replacing any restart already
    /// waiting (that is the debounce). `attempt` drives the retry backoff.
    private func scheduleRestart(reason: String, after delay: TimeInterval, attempt: Int) {
        restartQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.isCapturing }) else { return }
            self.pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.performRestart(reason: reason, attempt: attempt)
            }
            self.pendingRestart = work
            self.restartQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Runs on `restartQueue`.
    private func performRestart(reason: String, attempt: Int) {
        pendingRestart = nil
        guard lock.withLock({ isCapturing }) else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try configureAndStart()
            let count = lock.withLock { () -> Int in
                lastRestartTime = Self.nowHostSeconds()
                _restartCount += 1
                return _restartCount
            }
            print("[MicCapturer] engine restarted (\(reason), restart #\(count))")
            onRestart?(reason)
        } catch {
            let wait = min(2.0, 0.25 * pow(2.0, Double(attempt)))
            print("[MicCapturer] restart failed (\(reason)): \(error); retrying in \(wait)s")
            let work = DispatchWorkItem { [weak self] in
                self?.performRestart(reason: reason, attempt: attempt + 1)
            }
            pendingRestart = work
            restartQueue.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    /// Restarts the engine if it has stopped delivering without a notification.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: restartQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.lock.withLock({ self.isCapturing }) else { return }
            let now = Self.nowHostSeconds()
            let (lastBuffer, lastRestart) = self.lock.withLock { (self.lastBufferTime, self.lastRestartTime) }
            let silent = now - lastBuffer                    // since the last audio actually arrived
            let idle = now - max(lastBuffer, lastRestart)    // gives a fresh restart time to deliver
            if silent < Self.stallAfter { self.reportedUnresponsive = false }
            if silent >= Self.unresponsiveAfter, !self.reportedUnresponsive {
                self.reportedUnresponsive = true
                self.onUnresponsive?()
            }
            guard idle >= Self.stallAfter else { return }
            // A restart is already waiting (debounce or retry backoff).
            guard self.pendingRestart == nil else { return }
            print("[MicCapturer] no audio for \(String(format: "%.1f", silent))s; restarting")
            self.performRestart(reason: "stall", attempt: 0)
        }
        restartQueue.sync { watchdog = timer }
        timer.resume()
    }

    // MARK: Time

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func hostTime(_ ht: UInt64) -> TimeInterval {
        let nanos = Double(ht) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1e9
    }

    public static func nowHostSeconds() -> TimeInterval {
        hostTime(mach_absolute_time())
    }
}
