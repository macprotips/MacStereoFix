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
        return Array(ids.prefix(Int(dataSize) / MemoryLayout<AudioDeviceID>.size))
    }

    static func allOutputDevices() -> [AudioOutputDevice] {
        var result: [AudioOutputDevice] = []
        for id in allDeviceIDs() {
            guard hasOutputChannels(deviceID: id),
                  uintProperty(id, selector: kAudioDevicePropertyDeviceIsAlive) == 1 else { continue }
            let transport = uintProperty(id, selector: kAudioDevicePropertyTransportType)
            // An aggregate or virtual output can contain our input and create a loop.
            guard transport != nil, transport != kAudioDeviceTransportTypeVirtual,
                  transport != kAudioDeviceTransportTypeAggregate,
                  transport != kAudioDeviceTransportTypeAutoAggregate else { continue }
            guard let uid = deviceUID(id), !uid.isEmpty else { continue }
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
        let header = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard Int(dataSize) >= header else { return false }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard Int(bufferList.pointee.mNumberBuffers) <= (Int(dataSize) - header) / MemoryLayout<AudioBuffer>.stride else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        var totalChannels = 0
        for i in 0..<abl.count {
            totalChannels += Int(abl[i].mNumberChannels)
        }
        return totalChannels >= 2
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

    static func macStereoFixDriverVersion() -> String? {
        guard let device = macStereoFixDeviceID() else { return nil }
        return stringProperty(deviceID: device, selector: kAudioObjectPropertyFirmwareVersion,
                              scope: kAudioObjectPropertyScopeGlobal)
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

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
    }

    static func sampleRate(_ id: AudioDeviceID) -> Float64? {
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              value.isFinite else { return nil }
        return value
    }

    private static func uintProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Restore only the default owned by this app; preserve changes made in Sound settings.
    @discardableResult
    static func restoreOutput(preferredUID: String?) -> Bool {
        let current = defaultOutputDevice()
        guard current != 0, let currentUID = deviceUID(current) else { return false }
        guard currentUID == macStereoFixUID else { return true }
        let outputs = allOutputDevices()
        let preferred = outputs.first { $0.uid == preferredUID }
        let systemID = uintProperty(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        let system = outputs.first { $0.id == systemID }
        var candidates = [preferred, system].compactMap { $0 }
        candidates += outputs.filter { !candidates.contains($0) }
        for device in candidates {
            if setDefaultOutputDevice(device.id), defaultOutputDevice() == device.id { return true }
        }
        return false
    }

    // MARK: - Volume control bridge

    /// Find the output-scope volume control owned by a device, if any.
    /// MacStereoFix exposes one so the helper app can observe hardware
    /// volume-key presses and mirror them to the real output device.
    static func outputControlID(for deviceID: AudioDeviceID, class expectedClass: AudioClassID) -> AudioObjectID? {
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
        controls = Array(controls.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))

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
            if classID != expectedClass { continue }
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
            return v.isFinite ? min(max(v, 0), 1) : nil
        }
        return nil
    }

    /// Write the 0...1 scalar value of a level/volume control object.
    @discardableResult
    static func setControlScalarValue(_ controlID: AudioObjectID, _ value: Float) -> Bool {
        guard value.isFinite else { return false }
        var v: Float32 = max(0, min(1, value))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(controlID, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func controlMuted(_ controlID: AudioObjectID) -> Bool? {
        uintProperty(controlID, selector: kAudioBooleanControlPropertyValue).map { $0 != 0 }
    }

    @discardableResult
    static func setControlMuted(_ controlID: AudioObjectID, _ muted: Bool) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioBooleanControlPropertyValue,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(controlID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
