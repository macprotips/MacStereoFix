// SystemAudio.swift
//
// Thin wrappers around CoreAudio's AudioObject* APIs to enumerate output
// devices, look up the MacStereoFix virtual device by UID, and get/set the
// system default output device.

import Foundation
import CoreAudio

// MARK: - AudioOutputDevice

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

// MARK: - SystemAudio

enum SystemAudio {

    /// UID the MacStereoFix driver exposes its device under (must match the
    /// driver's kDevice_UID).
    static let macStereoFixUID = "MacStereoFixDevice_UID"

    // MARK: - Device enumeration

    /// Returns all AudioDeviceIDs known to the system.
    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        if count == 0 { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids
    }

    static func allOutputDevices() -> [AudioOutputDevice] {
        var result: [AudioOutputDevice] = []
        for id in allDeviceIDs() {
            guard hasOutputChannels(deviceID: id) else { continue }
            let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal) ?? ""
            let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) ?? "(unknown)"
            result.append(AudioOutputDevice(id: id, uid: uid, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasOutputChannels(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr else { return false }
        if dataSize == 0 { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, raw) == noErr else { return false }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        var totalChannels = 0
        for i in 0..<abl.count {
            totalChannels += Int(abl[i].mNumberChannels)
        }
        return totalChannels > 0
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr else { return nil }
        if dataSize != UInt32(MemoryLayout<CFString?>.size) { return nil }
        var cfStr: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let cf = cfStr else { return nil }
        return cf.takeRetainedValue() as String
    }

    // MARK: - MacStereoFix lookup

    static func macStereoFixDeviceID() -> AudioDeviceID? {
        for id in allDeviceIDs() {
            if let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal),
               uid == macStereoFixUID {
                return id
            }
        }
        return nil
    }

    static func isInstalled() -> Bool {
        return macStereoFixDeviceID() != nil
    }

    // MARK: - Default output device

    static func defaultOutputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }

    @discardableResult
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        return status == noErr
    }

    // MARK: - Per-device output volume

    /// Read the current output volume (0...1) for a device. Tries the main
    /// element first; falls back to averaging channels 1 and 2 for devices
    /// that only support per-channel volume. Matches `setDeviceVolume`, which
    /// writes both channels in the same fallback path — reading only ch1
    /// while writing both would make the slider disagree with reality on
    /// devices where L/R volumes have drifted apart.
    /// Returns nil if the device exposes no volume control.
    static func deviceVolume(_ deviceID: AudioDeviceID) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        var sum: Float = 0
        var count: Int = 0
        for ch: AudioObjectPropertyElement in [1, 2] {
            addr.mElement = ch
            if AudioObjectHasProperty(deviceID, &addr) {
                var vol: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr {
                    sum += vol
                    count += 1
                }
            }
        }
        return count > 0 ? sum / Float(count) : nil
    }

    /// Set the output volume (0...1) on a device. Tries the main element
    /// first; falls back to all output channels for devices that only support
    /// per-channel volume. Returns true if at least one element was updated.
    @discardableResult
    static func setDeviceVolume(_ deviceID: AudioDeviceID, _ value: Float) -> Bool {
        var v: Float32 = max(0, min(1, value))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr, settable.boolValue {
                if AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                              UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                    return true
                }
            }
        }
        var anySuccess = false
        for ch: AudioObjectPropertyElement in [1, 2] {
            addr.mElement = ch
            if AudioObjectHasProperty(deviceID, &addr) {
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr, settable.boolValue {
                    if AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                                  UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                        anySuccess = true
                    }
                }
            }
        }
        return anySuccess
    }

    // MARK: - Volume control bridge

    /// Find the output-scope volume control owned by a device, if any.
    /// MacStereoFix exposes one so the helper app can observe hardware
    /// volume-key presses and mirror them to the real output device.
    static func outputVolumeControlID(for deviceID: AudioDeviceID) -> AudioObjectID? {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyControlList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &listAddr, 0, nil, &size) == noErr else { return nil }
        if size == 0 { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        if count == 0 { return nil }
        var controls = [AudioObjectID](repeating: 0, count: count)
        let status = controls.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &listAddr, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr else { return nil }

        var classAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var scopeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioControlPropertyScope,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for controlID in controls {
            var classID: AudioClassID = 0
            var classSize = UInt32(MemoryLayout<AudioClassID>.size)
            guard AudioObjectGetPropertyData(controlID, &classAddr, 0, nil, &classSize, &classID) == noErr else { continue }
            if classID != kAudioVolumeControlClassID { continue }
            var scope: AudioObjectPropertyScope = 0
            var scopeSize = UInt32(MemoryLayout<AudioObjectPropertyScope>.size)
            guard AudioObjectGetPropertyData(controlID, &scopeAddr, 0, nil, &scopeSize, &scope) == noErr else { continue }
            if scope == kAudioObjectPropertyScopeOutput {
                return controlID
            }
        }
        return nil
    }

    /// Read the 0...1 scalar value of a level/volume control object.
    static func controlScalarValue(_ controlID: AudioObjectID) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(controlID, &addr, 0, nil, &size, &v) == noErr {
            return v
        }
        return nil
    }

    /// Write the 0...1 scalar value of a level/volume control object.
    @discardableResult
    static func setControlScalarValue(_ controlID: AudioObjectID, _ value: Float) -> Bool {
        var v: Float32 = max(0, min(1, value))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(controlID, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    /// Install a listener on a volume control's scalar-value property.
    /// Returns the block that must be retained by the caller and passed
    /// back to `removeControlScalarListener` for clean removal.
    static func installControlScalarListener(
        on controlID: AudioObjectID,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) -> AudioObjectPropertyListenerBlock? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(controlID, &addr, queue, block)
        return status == noErr ? block : nil
    }

    /// Remove a previously-installed scalar-value listener. Must be called
    /// with the exact same control ID, queue, and block used to install it.
    static func removeControlScalarListener(
        on controlID: AudioObjectID,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(controlID, &addr, queue, block)
    }
}
