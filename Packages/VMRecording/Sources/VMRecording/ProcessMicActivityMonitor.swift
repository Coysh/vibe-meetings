import CoreAudio
import Darwin
import Foundation

/// A process (other than us) that currently has microphone input running.
public struct MicClient: Sendable, Hashable {
    public let pid: pid_t
    /// Bundle ID as reported by Core Audio. Helper processes report their own
    /// ID (`com.google.Chrome.helper`), daemons may report none.
    public let bundleID: String?
    /// Short process name from the kernel (`avconferenced`, `zoom.us`).
    public let processName: String?

    public init(pid: pid_t, bundleID: String?, processName: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.processName = processName
    }
}

public struct MicUsageSnapshot: Sendable, Equatable {
    /// Processes with input running, excluding this process.
    public var clients: [MicClient]
    /// Whether the *current* default input device is running for anyone
    /// (including us). Only meaningful as a fallback when
    /// `processListAvailable` is false.
    public var defaultDeviceRunningSomewhere: Bool
    /// False if Core Audio refused the process-object query, in which case
    /// callers should fall back to `defaultDeviceRunningSomewhere`.
    public var processListAvailable: Bool

    public static let empty = MicUsageSnapshot(clients: [], defaultDeviceRunningSomewhere: false, processListAvailable: true)
}

/// Reports which processes are using a microphone, on any input device.
///
/// Uses the Core Audio process objects (macOS 14+): every process with an
/// audio client appears in `kAudioHardwarePropertyProcessObjectList`, and
/// `kAudioProcessPropertyIsRunningInput` says whether it is capturing. Unlike
/// watching `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default
/// device, this keeps working when the user switches to AirPods/a headset
/// mid-day, and it tells us *who* holds the mic.
///
/// All mutable state is confined to `queue`; Core Audio listener blocks are
/// delivered on the same queue. A 5 s poll backs up the listeners in case a
/// notification is missed.
public final class ProcessMicActivityMonitor: @unchecked Sendable {
    public let snapshots: AsyncStream<MicUsageSnapshot>
    private let continuation: AsyncStream<MicUsageSnapshot>.Continuation

    private let queue = DispatchQueue(label: "VibeMeetings.ProcessMicActivityMonitor")
    private let ownPID = getpid()

    // Queue-confined state.
    private var running = false
    private var last: MicUsageSnapshot?
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var pollTimer: DispatchSourceTimer?

    public init() {
        let (stream, cont) = AsyncStream.makeStream(of: MicUsageSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        self.snapshots = stream
        self.continuation = cont
    }

    deinit {
        continuation.finish()
    }

    /// Begin monitoring. Emits the initial snapshot immediately. Idempotent.
    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            installSystemListeners()
            rebindProcessListeners()
            rebindDeviceListener()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.emitIfChanged() }
            timer.resume()
            pollTimer = timer

            last = nil
            emitIfChanged()
        }
    }

    public func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            pollTimer?.cancel(); pollTimer = nil
            for (addr, block) in systemListeners {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
            }
            systemListeners.removeAll()
            for id in Array(processListeners.keys) { removeProcessListener(id) }
            removeDeviceListener()
        }
    }

    /// Synchronously computes the current state (safe from any thread).
    public func currentSnapshot() -> MicUsageSnapshot {
        queue.sync { computeSnapshot() }
    }

    // MARK: - Listeners (queue-confined)

    private func installSystemListeners() {
        let processList = Self.address(kAudioHardwarePropertyProcessObjectList)
        let defaultInput = Self.address(kAudioHardwarePropertyDefaultInputDevice)

        let onProcessList: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebindProcessListeners()
            self?.emitIfChanged()
        }
        let onDefaultInput: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebindDeviceListener()
            self?.emitIfChanged()
        }
        for (addr, block) in [(processList, onProcessList), (defaultInput, onDefaultInput)] {
            var a = addr
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
            if status == noErr {
                systemListeners.append((addr, block))
            } else {
                print("[ProcessMicMonitor] failed to add system listener \(addr.mSelector): OSStatus \(status)")
            }
        }
    }

    /// Keep exactly one `IsRunningInput` listener per current process object.
    private func rebindProcessListeners() {
        guard running else { return }
        let current = Set(Self.processObjectIDs() ?? [])
        for gone in Set(processListeners.keys).subtracting(current) {
            removeProcessListener(gone)
        }
        for new in current.subtracting(processListeners.keys) {
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.emitIfChanged() }
            if AudioObjectAddPropertyListenerBlock(new, &addr, queue, block) == noErr {
                processListeners[new] = block
            }
        }
    }

    private func removeProcessListener(_ id: AudioObjectID) {
        guard let block = processListeners.removeValue(forKey: id) else { return }
        var addr = Self.address(kAudioProcessPropertyIsRunningInput)
        // May fail if the process object is already gone — harmless.
        AudioObjectRemovePropertyListenerBlock(id, &addr, queue, block)
    }

    /// Follow the default input device so the fallback signal survives
    /// device switches.
    private func rebindDeviceListener() {
        guard running else { return }
        let newID = AudioDeviceEnumerator.defaultInputDeviceID() ?? AudioObjectID(kAudioObjectUnknown)
        guard newID != deviceID else { return }
        removeDeviceListener()
        deviceID = newID
        guard newID != kAudioObjectUnknown else { return }
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.emitIfChanged() }
        if AudioObjectAddPropertyListenerBlock(newID, &addr, queue, block) == noErr {
            deviceListener = block
        }
    }

    private func removeDeviceListener() {
        if let block = deviceListener, deviceID != kAudioObjectUnknown {
            var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue, block)
        }
        deviceListener = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func emitIfChanged() {
        guard running else { return }
        let snap = computeSnapshot()
        guard snap != last else { return }
        last = snap
        continuation.yield(snap)
    }

    // MARK: - Reading state

    private func computeSnapshot() -> MicUsageSnapshot {
        let deviceRunning: Bool = {
            guard let dev = AudioDeviceEnumerator.defaultInputDeviceID() else { return false }
            return (Self.readUInt32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
        }()
        guard let ids = Self.processObjectIDs() else {
            return MicUsageSnapshot(clients: [], defaultDeviceRunningSomewhere: deviceRunning, processListAvailable: false)
        }
        var clients: [MicClient] = []
        for id in ids {
            guard (Self.readUInt32(id, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                  let pid = Self.readPID(id), pid != ownPID
            else { continue }
            clients.append(MicClient(pid: pid, bundleID: Self.readBundleID(id), processName: Self.processName(pid)))
        }
        clients.sort { $0.pid < $1.pid }
        return MicUsageSnapshot(clients: clients, defaultDeviceRunningSomewhere: deviceRunning, processListAvailable: true)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjectIDs() -> [AudioObjectID]? {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func readUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func readPID(_ id: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        return pid
    }

    private static func readBundleID(_ id: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let len = proc_name(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(len)), as: UTF8.self)
    }
}
