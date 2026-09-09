import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var isBusy = false
    @Published private(set) var driverInstalled = false
    @Published private(set) var availableOutputs: [AudioOutputDevice] = []
    @Published private(set) var lastError: String?
    @Published private(set) var statusMessage: String?
    @Published var selectedOutputUID: String? {
        didSet { defaults.set(selectedOutputUID, forKey: "selectedOutputUID") }
    }
    @Published var dialogueBoostDB: Float = 3 {
        didSet {
            router.setDialogueBoostDB(dialogueBoostDB)
            defaults.set(dialogueBoostDB, forKey: "dialogueBoostDB")
        }
    }
    /// Software attenuation; never changes hardware volume or channel balance.
    @Published var outputVolume: Float = 1 {
        didSet {
            router.setOutputVolume(isMuted ? 0 : outputVolume)
            defaults.set(outputVolume, forKey: "routingVolume")
            if let control = virtualVolumeControlID, !updatingVolume {
                SystemAudio.setControlScalarValue(control, outputVolume)
            }
        }
    }
    @Published var isMuted = false {
        didSet {
            router.setOutputVolume(isMuted ? 0 : outputVolume)
            if let control = virtualMuteControlID, !updatingVolume {
                SystemAudio.setControlMuted(control, isMuted)
            }
        }
    }

    private let defaults: UserDefaults
    private let router = AudioRouter()
    private let recovery = AudioRecovery()
    private var previousOutputUID: String?
    private var routedDeviceID: AudioDeviceID?
    private var generation = 0
    private var observations: [AudioObservation] = []
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var healthTimer: Timer?
    private var lastProgress: (capture: UInt64, render: UInt64) = (0, 0)
    private var stalledChecks = 0
    private var virtualVolumeControlID: AudioObjectID?
    private var volumeObservation: AudioObservation?
    private var virtualMuteControlID: AudioObjectID?
    private var muteObservation: AudioObservation?
    private var updatingVolume = false
    private var driverChangeInProgress = false
    private let requestPermission: () async -> Bool

    init(defaults: UserDefaults = .standard,
         requestPermission: @escaping () async -> Bool = AppState.requestAudioPermission) {
        self.defaults = defaults
        self.requestPermission = requestPermission
        // Read the preference before device enumeration can select a fallback.
        selectedOutputUID = defaults.string(forKey: "selectedOutputUID")
        previousOutputUID = defaults.string(forKey: "recoveryOutputUID")
        if let value = defaults.object(forKey: "dialogueBoostDB") as? NSNumber,
           value.floatValue.isFinite {
            dialogueBoostDB = min(max(value.floatValue, 0), 9)
        }
        if let value = defaults.object(forKey: "routingVolume") as? NSNumber,
           value.floatValue.isFinite {
            outputVolume = min(max(value.floatValue, 0), 1)
        }
        router.setDialogueBoostDB(dialogueBoostDB)
        router.setOutputVolume(outputVolume)
        refreshDevices()
        recoverOutput()
        // Always start off. A crash, login, or permission prompt must not
        // silently re-enable system-wide capture.
        defaults.removeObject(forKey: "wasOn")

        if let listener = AudioObservation(selector: kAudioHardwarePropertyDevices,
            handler: { [weak self] in self?.refreshDevices() }) { observations.append(listener) }
        if let listener = AudioObservation(selector: kAudioHardwarePropertyDefaultOutputDevice,
            handler: { [weak self] in self?.defaultOutputChanged() }) { observations.append(listener) }
        observe(.default, NSApplication.willTerminateNotification) { [weak self] in self?.turnOff() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in
            guard let self else { return }
            self.turnOff()
            self.statusMessage = "Paused for sleep. Turn Force Stereo on when you're ready."
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.refreshDevices()
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAudioHealth() }
        }
    }

    deinit {
        healthTimer?.invalidate()
        for (center, token) in notifications { center.removeObserver(token) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        notifications.append((center, token))
    }

    func refreshDevices() {
        let devices = SystemAudio.allOutputDevices()
        availableOutputs = devices
        driverInstalled = DriverManager.isInstalled()
        let selected = devices.first { $0.uid == selectedOutputUID }
        if isOn && (selected == nil || selected?.id != routedDeviceID || !driverInstalled) {
            stopWithError("Audio device disconnected or restarted. Select your output and turn Force Stereo on again.")
        }
        if selected == nil {
            selectedOutputUID = devices.first { $0.id == SystemAudio.defaultOutputDevice() }?.uid ?? devices.first?.uid
        }
        if !isOn && !isBusy { recoverOutput() }
    }

    private func defaultOutputChanged() {
        guard isOn, SystemAudio.defaultOutputDevice() != SystemAudio.macStereoFixDeviceID() else { return }
        turnOff()
        statusMessage = "Force Stereo stopped because the output changed in macOS."
    }

    private func recoverOutput() {
        if SystemAudio.restoreOutput(preferredUID: previousOutputUID ?? selectedOutputUID) {
            recovery.disarm()
            defaults.removeObject(forKey: "recoveryOutputUID")
        } else {
            lastError = "Could not restore sound. Open System Settings → Sound → Output and choose your speakers or headphones."
        }
    }

    func toggle() {
        guard !isBusy else { return }
        if isOn { turnOff() } else { turnOn() }
    }

    func turnOn() {
        guard !isOn, !isBusy else { return }
        lastError = nil
        statusMessage = nil
        isBusy = true
        generation += 1
        let request = generation
        let requestedOutput = selectedOutputUID
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.requestPermission()
            guard self.generation == request else { return }
            guard allowed else {
                self.isBusy = false
                self.lastError = "Allow MacStereoFix in System Settings → Privacy & Security → Microphone, then try again. It reads the virtual audio device, not your physical microphone."
                return
            }
            guard self.selectedOutputUID == requestedOutput else {
                self.isBusy = false
                self.lastError = "The selected output changed while waiting for permission. Select your output and try again."
                return
            }
            await self.startRouting(request: request)
        }
    }

    private func startRouting(request: Int) async {
        defer { if generation == request { isBusy = false } }
        guard let uid = selectedOutputUID,
              let target = availableOutputs.first(where: { $0.uid == uid }),
              DriverManager.isInstalled(), let virtual = SystemAudio.macStereoFixDeviceID() else {
            lastError = "Install the current driver and select an available stereo output first."
            return
        }
        let current = SystemAudio.defaultOutputDevice()
        previousOutputUID = current == virtual ? target.uid : SystemAudio.deviceUID(current) ?? target.uid
        defaults.set(previousOutputUID, forKey: "recoveryOutputUID")
        do {
            try recovery.arm(preferredUID: previousOutputUID)
            try router.start(outputDevice: target.id)
            // Confirm both callbacks run before moving any app's sound to the driver.
            for _ in 0..<100 {
                guard generation == request else { return }
                let progress = router.progress
                if progress.capture > 0 && progress.render > 0 { break }
                if router.audioFailed { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard generation == request else { return }
            let progress = router.progress
            guard !router.audioFailed, progress.capture > 0, progress.render > 0, recovery.isRunning else {
                throw RoutingError.message("Audio could not start. Your normal output was kept. Check audio permission and reconnect your output device.")
            }
            guard selectedOutputUID == uid, SystemAudio.allOutputDevices().contains(target),
                  DriverManager.isInstalled(), SystemAudio.sampleRate(target.id) == router.outputSampleRate else {
                throw RoutingError.message("The selected audio device changed while starting. Select your output and try again.")
            }
            guard SystemAudio.defaultOutputDevice() == current else {
                throw RoutingError.message("The macOS output changed while starting. Try again with the output you want.")
            }
            setupVirtualVolume(virtual)
            guard SystemAudio.setDefaultOutputDevice(virtual), SystemAudio.defaultOutputDevice() == virtual else {
                throw RoutingError.message("Could not select MacStereoFix as the output.")
            }
            routedDeviceID = target.id
            lastProgress = router.progress
            stalledChecks = 0
            isOn = true
        } catch {
            stopWithError(error.localizedDescription)
        }
    }

    private func stopWithError(_ message: String) {
        let restored = turnOff()
        lastError = restored ? message : message + " Choose your speakers or headphones in System Settings → Sound → Output to restore sound."
    }

    @discardableResult
    func turnOff() -> Bool {
        generation += 1
        // Restore before stopping capture/render; preserve a user's manual output change.
        let restored = SystemAudio.restoreOutput(preferredUID: previousOutputUID ?? selectedOutputUID)
        volumeObservation = nil
        muteObservation = nil
        virtualVolumeControlID = nil
        virtualMuteControlID = nil
        router.stop()
        routedDeviceID = nil
        isOn = false
        isBusy = driverChangeInProgress
        if restored {
            recovery.disarm()
            defaults.removeObject(forKey: "recoveryOutputUID")
        } else {
            lastError = "Could not restore sound. Choose your speakers or headphones in System Settings → Sound → Output."
        }
        return restored
    }

    func selectOutput(_ uid: String) {
        guard !isBusy else { return }
        let resume = isOn
        if resume && !turnOff() { return }
        selectedOutputUID = uid.isEmpty ? nil : uid
        if resume { turnOn() }
    }

    private func setupVirtualVolume(_ virtual: AudioDeviceID) {
        if let muteControl = SystemAudio.outputControlID(for: virtual, class: kAudioMuteControlClassID) {
            virtualMuteControlID = muteControl
            SystemAudio.setControlMuted(muteControl, isMuted)
            muteObservation = AudioObservation(object: muteControl, selector: kAudioBooleanControlPropertyValue) { [weak self] in
                guard let self, let value = SystemAudio.controlMuted(muteControl) else { return }
                self.updatingVolume = true
                self.isMuted = value
                self.updatingVolume = false
            }
        }
        guard let control = SystemAudio.outputControlID(for: virtual, class: kAudioVolumeControlClassID) else { return }
        virtualVolumeControlID = control
        SystemAudio.setControlScalarValue(control, outputVolume)
        volumeObservation = AudioObservation(object: control, selector: kAudioLevelControlPropertyScalarValue) { [weak self] in
            guard let self, let value = SystemAudio.controlScalarValue(control) else { return }
            self.updatingVolume = true
            self.outputVolume = value
            self.updatingVolume = false
        }
    }

    private func checkAudioHealth() {
        guard isOn else { return }
        router.updateClockDrift()
        let progress = router.progress
        let stalled = progress.capture == lastProgress.capture || progress.render == lastProgress.render
        stalledChecks = stalled ? stalledChecks + 1 : 0
        lastProgress = progress
        let rateChanged = routedDeviceID.map { SystemAudio.sampleRate($0) != router.outputSampleRate } ?? true
        if router.audioFailed || stalledChecks >= 3 || rateChanged || !recovery.isRunning {
            stopWithError("Audio routing stopped working, so Force Stereo was turned off. Check your output device and try again.")
        }
    }

    func installDriver() { changeDriver(install: true) }
    func uninstallDriver() { changeDriver(install: false) }

    private func changeDriver(install: Bool) {
        guard !isBusy else { return }
        // Removal must remain possible on a headless Mac with no physical
        // output. Always stop IO, even when there is nowhere to restore sound.
        let restored = turnOff()
        lastError = nil
        statusMessage = install ? "Installing driver…" : "Removing driver…"
        isBusy = true
        driverChangeInProgress = true
        Task { [weak self] in
            let error = await Task.detached {
                install ? DriverManager.installDriver() : DriverManager.uninstallDriver()
            }.value
            guard let self else { return }
            if let error {
                self.statusMessage = nil
                self.lastError = error
            } else {
                self.statusMessage = install ? "Driver copied. Waiting for macOS audio…" : "Driver removed."
            }
            // Registration can take longer than a fixed 1.5-second delay.
            self.refreshDevices()
            if error == nil {
                for _ in 0..<20 {
                    if install == self.driverInstalled { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self.refreshDevices()
                }
            }
            if error == nil && install {
                self.statusMessage = self.driverInstalled ? "Driver ready." : nil
                if !self.driverInstalled { self.lastError = "Driver copied, but macOS hasn't loaded it. Restart your Mac, then try again." }
            }
            self.driverChangeInProgress = false
            self.isBusy = false
            if !restored && error == nil { self.recoverOutput() }
        }
    }

    private enum RoutingError: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let text): return text } }
    }

    nonisolated static func requestAudioPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
