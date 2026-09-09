import AppKit
import CoreAudio
import Foundation

// Test doubles replace CoreAudio and installer side effects. AppState itself is
// the production file; no test changes the Mac's output or requests permission.
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}
enum SystemAudio {
    static let speakers = AudioOutputDevice(id: 10, uid: "speakers", name: "Speakers")
    static let headphones = AudioOutputDevice(id: 11, uid: "headphones", name: "Headphones")
    static var devices = [speakers, headphones]
    static var current: AudioDeviceID = 10
    static var rejectDefault = false
    static var virtualWrites = 0
    static func allOutputDevices() -> [AudioOutputDevice] { devices }
    static func macStereoFixDeviceID() -> AudioDeviceID? { 99 }
    static func defaultOutputDevice() -> AudioDeviceID { current }
    static func deviceUID(_ id: AudioDeviceID) -> String? { devices.first { $0.id == id }?.uid }
    static func sampleRate(_ id: AudioDeviceID) -> Float64? { 48000 }
    static func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
        if rejectDefault { return false }
        current = id
        if id == 99 { virtualWrites += 1 }
        return true
    }
    static func restoreOutput(preferredUID: String?) -> Bool {
        if current != 99 { return true }
        guard let target = devices.first(where: { $0.uid == preferredUID }) ?? devices.first else { return false }
        return setDefaultOutputDevice(target.id)
    }
    static func outputControlID(for id: AudioDeviceID, class expectedClass: AudioClassID) -> AudioObjectID? {
        expectedClass == kAudioMuteControlClassID ? 21 : 20
    }
    static func setControlScalarValue(_ id: AudioObjectID, _ value: Float) {}
    static func controlScalarValue(_ id: AudioObjectID) -> Float? { 0.5 }
    static func setControlMuted(_ id: AudioObjectID, _ muted: Bool) {}
    static func controlMuted(_ id: AudioObjectID) -> Bool? { true }
    static func reset() { devices = [speakers, headphones]; current = 10; rejectDefault = false; virtualWrites = 0 }
}
final class AudioObservation {
    static var handlers: [AudioObjectPropertySelector: @MainActor () -> Void] = [:]
    init?(object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
          selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) {
        Self.handlers[selector] = handler
    }
}
final class AudioRouter {
    static var failStart = false
    static var startCount = 0
    static var stopCount = 0
    static var volume: Float = 1
    var audioFailed = false
    var outputSampleRate: Float64 = 48000
    var progress: (capture: UInt64, render: UInt64) { (1, 1) }
    func start(outputDevice: AudioDeviceID) throws {
        Self.startCount += 1
        if Self.failStart { throw NSError(domain: "Injected audio failure", code: 1) }
    }
    func stop() { Self.stopCount += 1 }
    func setDialogueBoostDB(_ value: Float) {}
    func setOutputVolume(_ value: Float) { Self.volume = value }
    func updateClockDrift() {}
}
final class AudioRecovery {
    static var failArm = false
    var isRunning = false
    func arm(preferredUID: String?) throws {
        if Self.failArm { throw NSError(domain: "Injected recovery failure", code: 1) }
        isRunning = true
    }
    func disarm() { isRunning = false }
}
enum DriverManager {
    static var installed = true
    static func isInstalled() -> Bool { installed }
    static func installDriver() -> String? { "Injected installer failure" }
    static func uninstallDriver() -> String? { "Injected removal failure" }
}

@main
struct StateTests {
    @MainActor static func main() async {
        let suite = "com.macstereofix.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func reset() {
            defaults.removePersistentDomain(forName: suite)
            SystemAudio.reset()
            AudioRouter.failStart = false
            AudioRouter.startCount = 0
            AudioRouter.stopCount = 0
            AudioRecovery.failArm = false
            DriverManager.installed = true
        }
        reset()
        do {
            defaults.set("headphones", forKey: "selectedOutputUID")
            let state = AppState(defaults: defaults, requestPermission: { true })
            assert(state.selectedOutputUID == "headphones")
            assert(defaults.string(forKey: "selectedOutputUID") == "headphones")
            assert(state.dialogueBoostDB == 0, "Dialogue boost must be opt-in")
            state.dialogueBoostDB = 6
            let restored = AppState(defaults: defaults, requestPermission: { true })
            assert(restored.dialogueBoostDB == 6, "Keep an explicitly saved boost")
        }
        reset()
        do {
            SystemAudio.current = 99
            defaults.set("headphones", forKey: "recoveryOutputUID")
            defaults.set(true, forKey: "wasOn")
            let state = AppState(defaults: defaults, requestPermission: { true })
            assert(!state.isOn && SystemAudio.current == 11 && AudioRouter.startCount == 0)
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: { false })
            state.turnOn()
            await settle(state)
            assert(!state.isOn && state.lastError != nil && SystemAudio.current == 10 && AudioRouter.startCount == 0)
        }
        reset()
        do {
            AudioRecovery.failArm = true
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.turnOn()
            await settle(state)
            assert(!state.isOn && SystemAudio.virtualWrites == 0 && state.lastError != nil)
        }
        reset()
        do {
            AudioRouter.failStart = true
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.turnOn()
            await settle(state)
            assert(!state.isOn && SystemAudio.virtualWrites == 0 && AudioRouter.stopCount > 0)
        }
        reset()
        do {
            SystemAudio.rejectDefault = true
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.turnOn()
            await settle(state)
            assert(!state.isOn && SystemAudio.current == 10 && state.lastError != nil)
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.turnOn()
            await settle(state)
            assert(state.isOn && SystemAudio.current == 99)
            state.outputVolume = 0.3
            state.isMuted = true
            assert(AudioRouter.volume == 0)
            state.isMuted = false
            assert(AudioRouter.volume == 0.3)
            state.turnOff()
            assert(SystemAudio.current == 10 && !state.isOn)
            // A second Off must not override a later manual output selection.
            SystemAudio.current = 11
            state.turnOff()
            assert(SystemAudio.current == 11)
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.turnOn()
            await settle(state)
            AudioRouter.failStart = true
            state.selectOutput("headphones")
            await settle(state)
            assert(!state.isOn && SystemAudio.current != 99 && state.lastError != nil)
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.selectOutput("headphones")
            state.turnOn()
            await settle(state)
            SystemAudio.devices = [SystemAudio.speakers]
            state.refreshDevices()
            assert(!state.isOn && SystemAudio.current == 10)
            SystemAudio.devices = []
            state.refreshDevices()
            assert(state.selectedOutputUID == nil)
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.turnOn()
            await settle(state)
            SystemAudio.current = 11
            AudioObservation.handlers[kAudioHardwarePropertyDefaultOutputDevice]?()
            assert(!state.isOn && SystemAudio.current == 11)
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return true
            })
            state.turnOn()
            state.turnOff()
            try? await Task.sleep(nanoseconds: 200_000_000)
            assert(!state.isOn && !state.isBusy && AudioRouter.startCount == 0)
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.turnOn()
            await settle(state)
            state.installDriver()
            await settle(state)
            assert(!state.isOn && SystemAudio.current == 10 && state.lastError == "Injected installer failure")
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return true
            })
            state.selectOutput("headphones")
            state.turnOn()
            SystemAudio.devices = [SystemAudio.speakers]
            state.refreshDevices()
            await settle(state)
            assert(!state.isOn && AudioRouter.startCount == 0 && SystemAudio.virtualWrites == 0)
        }
        reset()
        do {
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.turnOn()
            await settle(state)
            SystemAudio.devices = []
            state.refreshDevices()
            assert(!state.isOn && state.selectedOutputUID == nil && state.lastError?.contains("System Settings") == true)
        }
        reset()
        do {
            SystemAudio.devices = []
            SystemAudio.current = 99
            let state = AppState(defaults: defaults, requestPermission: { true })
            state.uninstallDriver()
            await settle(state)
            assert(state.lastError == "Injected removal failure") // removal was attempted
        }
        print("15 routing scenarios passed: preferences, startup recovery, permissions, start failures, mute, Off, switching, disconnect, manual change, cancellation, reinstall, startup device loss and removal without an output")
    }

    @MainActor static func settle(_ state: AppState) async {
        for _ in 0..<200 {
            if !state.isBusy { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        assertionFailure("State did not finish its operation")
    }
}
