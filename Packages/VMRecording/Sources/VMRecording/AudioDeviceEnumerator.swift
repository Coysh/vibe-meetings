import CoreAudio
import AVFoundation

/// Describes an audio input device suitable for display in a picker.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let sampleRate: Float64
    public let inputChannels: Int

    public var isDefault: Bool = false
}

/// Enumerates real audio input devices via Core Audio.
public enum AudioDeviceEnumerator {

    /// Returns all audio devices that have at least one input channel.
    public static func inputDevices() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for devID in deviceIDs {
            let channels = inputChannelCount(for: devID)
            guard channels > 0 else { continue }

            let name = deviceName(for: devID) ?? "Unknown Device"
            let uid = deviceUID(for: devID) ?? "\(devID)"
            let rate = nominalSampleRate(for: devID)

            result.append(AudioInputDevice(
                id: devID,
                uid: uid,
                name: name,
                sampleRate: rate,
                inputChannels: channels,
                isDefault: devID == defaultID
            ))
        }
        return result
    }

    /// The system default input device ID, or `nil` if unavailable.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    // MARK: - Private helpers

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var name: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? name as String : nil
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? uid as String : nil
    }

    private static func nominalSampleRate(for deviceID: AudioDeviceID) -> Float64 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
        return rate
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let layout = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { layout.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, layout) == noErr else { return 0 }

        let abl = UnsafeMutableAudioBufferListPointer(layout)
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
