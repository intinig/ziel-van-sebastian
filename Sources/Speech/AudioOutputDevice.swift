import Foundation
import CoreAudio

/// Case-insensitive substring match over output-capable CoreAudio devices.
/// Used to pin TTS playback to a specific device (e.g. the PowerConf) so mic
/// and speaker share one hardware unit for echo cancellation. `nil` = no match.
public enum AudioOutputDevice {
    public static func find(named name: String) -> AudioDeviceID? {
        guard !name.isEmpty else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return nil }
        for id in ids {
            var outAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &outAddr, 0, nil, &cfgSize) == noErr, cfgSize > 0 else { continue }
            // `cfgSize` is a byte count; allocate exactly that many bytes (not
            // `cfgSize` *elements* of AudioBufferList, which would over-allocate)
            // and bind the raw memory to the variable-length AudioBufferList type.
            let rawBuf = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize),
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawBuf.deallocate() }
            let buf = rawBuf.bindMemory(to: AudioBufferList.self, capacity: 1)
            guard AudioObjectGetPropertyData(id, &outAddr, 0, nil, &cfgSize, buf) == noErr,
                  UnsafeMutableAudioBufferListPointer(buf).reduce(0, { $0 + Int($1.mNumberChannels) }) > 0
            else { continue }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            // CoreAudio's Copy rule hands back a +1-retained CFString here; Swift's
            // ARC balances it with a release when `cfName` goes out of scope below —
            // fragile if this is ever refactored to hold the pointer/value longer.
            guard withUnsafeMutablePointer(to: &cfName, { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }) == noErr else { continue }
            if (cfName as String).localizedCaseInsensitiveContains(name) { return id }
        }
        return nil
    }

    /// The system's current default output device (whatever System Settings has
    /// selected — built-in speakers, AirPods, etc). Used to unpin TTS playback
    /// back to the default when `voice.outputDevice` is live-reloaded to "".
    /// `nil` on failure (caller degrades gracefully — no playback is ever
    /// blocked on this).
    public static func systemDefaultOutput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return nil }
        return deviceID
    }
}
