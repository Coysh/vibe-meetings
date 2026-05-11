import CoreAudio
import Foundation

/// Monitors the system default input device to detect when any app starts or
/// stops using the microphone. Emits changes via an `AsyncStream<Bool>`.
///
/// Uses `kAudioDevicePropertyDeviceIsRunningSomewhere` which fires whenever
/// *any* process activates or deactivates the input device (Zoom, Teams, etc.).
public final class MicrophoneActivityMonitor: @unchecked Sendable {
    public let isActive: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    private var deviceID: AudioDeviceID = 0
    private var listenerInstalled = false
    private var lastKnownState = false

    public init() {
        let (stream, cont) = AsyncStream.makeStream(of: Bool.self)
        self.isActive = stream
        self.continuation = cont
    }

    deinit {
        stop()
    }

    /// Begin monitoring. Safe to call multiple times — subsequent calls are no-ops.
    public func start() {
        guard !listenerInstalled else { return }

        guard let defaultID = AudioDeviceEnumerator.defaultInputDeviceID() else {
            print("[MicMonitor] no default input device found")
            return
        }
        self.deviceID = defaultID

        // Read the initial state.
        let running = isDeviceRunning(deviceID)
        lastKnownState = running
        continuation.yield(running)
        print("[MicMonitor] started, device=\(deviceID), initialRunning=\(running)")

        // Install the property listener.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListener(
            deviceID,
            &addr,
            micActivityChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status == noErr {
            listenerInstalled = true
        } else {
            print("[MicMonitor] failed to install listener: OSStatus \(status)")
        }
    }

    public func stop() {
        guard listenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            deviceID,
            &addr,
            micActivityChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        listenerInstalled = false
        continuation.finish()
    }

    // MARK: - Internal

    fileprivate func handleChange() {
        let running = isDeviceRunning(deviceID)
        guard running != lastKnownState else { return }
        lastKnownState = running
        print("[MicMonitor] mic running changed → \(running)")
        continuation.yield(running)
    }

    private func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }
}

/// C-function property listener callback — bridges to the Swift instance.
private func micActivityChanged(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let monitor = Unmanaged<MicrophoneActivityMonitor>.fromOpaque(clientData).takeUnretainedValue()
    monitor.handleChange()
    return noErr
}
