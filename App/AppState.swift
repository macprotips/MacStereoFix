// AppState.swift
//
// Single source of truth for the menu bar UI. Owns the AudioRouter, the
// device list, the toggle state, and the dialogue boost. Saves a tiny bit of
// state to UserDefaults so the user's preferred output device sticks across
// launches.

import Foundation
import CoreAudio
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    /// Master toggle: ON = audio is being routed through MacStereoFix.
    @Published var isOn: Bool = false

    /// Extra dB added on top of the -3 dB ITU center coefficient.
    @Published var dialogueBoostDB: Float = 3.0 {
        didSet {
            router.setDialogueBoostDB(dialogueBoostDB)
            UserDefaults.standard.set(dialogueBoostDB, forKey: "dialogueBoostDB")
        }
    }

    /// UID of the real output device stereo audio is sent to.
    @Published var selectedOutputUID: String? {
        didSet {
            if let uid = selectedOutputUID {
                UserDefaults.standard.set(uid, forKey: "selectedOutputUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedOutputUID")
            }
            // Picking a new device: sync the slider to that device's level.
            refreshOutputVolumeFromDevice()
        }
    }

    /// Volume of the currently selected real output device, 0...1.
    /// Setting this propagates to the device immediately.
    @Published var outputVolume: Float = 1.0 {
        didSet {
            guard !suppressVolumeWriteback else { return }
            guard let uid = selectedOutputUID,
                  let dev = availableOutputs.first(where: { $0.uid == uid }) else { return }
            SystemAudio.setDeviceVolume(dev.id, outputVolume)
            // Mirror slider writes to the virtual device's volume control
            // so the macOS volume HUD matches what the slider shows. When
            // running, this also keeps the hardware-volume-key baseline in
            // sync. The listener will fire but see no change and no-op.
            if isOn, let ctl = virtualVolumeControlID {
                SystemAudio.setControlScalarValue(ctl, outputVolume)
            }
        }
    }

    /// True if the selected device exposes any volume control at all.
    @Published private(set) var outputVolumeAvailable: Bool = false

    /// List of real output devices (excludes MacStereoFix itself).
    @Published private(set) var availableOutputs: [AudioOutputDevice] = []

    /// True when the MacStereoFix driver bundle is installed and visible.
    @Published private(set) var driverInstalled: Bool = false

    /// Latest user-facing error message, or nil.
    @Published private(set) var lastError: String?

    // MARK: - Private state

    private let router = AudioRouter()

    /// Device the user was on before we hijacked the default — restored on Off.
    private var previousDefaultDevice: AudioDeviceID = 0

    /// True while we're updating outputVolume from a device read, so the
    /// didSet observer doesn't write the same value back to Core Audio.
    private var suppressVolumeWriteback = false

    /// While running, the object ID of the MacStereoFix virtual device's
    /// output volume control, or nil if the installed driver predates the
    /// volume-control addition. Used to observe hardware volume-key presses.
    private var virtualVolumeControlID: AudioObjectID?

    /// Listener block installed on `virtualVolumeControlID`. Held so it can
    /// be removed cleanly on teardown — `AudioObjectRemovePropertyListenerBlock`
    /// requires the same block reference used at registration.
    private var virtualVolumeListenerBlock: AudioObjectPropertyListenerBlock?

    // MARK: - Init

    init() {
        // Load persisted prefs
        if let stored = UserDefaults.standard.object(forKey: "dialogueBoostDB") as? Double {
            self.dialogueBoostDB = Float(stored)
        }
        router.setDialogueBoostDB(self.dialogueBoostDB)

        // Populate the device list first, then apply the stored selection.
        // Doing this in the other order fires selectedOutputUID's didSet
        // against an empty availableOutputs list.
        refreshDevices()
        if let storedUID = UserDefaults.standard.string(forKey: "selectedOutputUID"),
           availableOutputs.contains(where: { $0.uid == storedUID }) {
            selectedOutputUID = storedUID
        }

        installDeviceListListener()
        installTerminationObserver()
        recoverFromCrashedSession()

        // Auto-resume: if the user had it on last time, turn it back on.
        if UserDefaults.standard.bool(forKey: "wasOn") {
            // Small delay so the menu bar UI has time to appear and the driver
            // device is fully registered after a fresh login / reboot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isOn, self.driverInstalled else { return }
                self.turnOn()
            }
        }
    }

    /// If a previous run crashed while toggled On, the system default output
    /// may still be pointing at MacStereoFix with nothing reading from it.
    /// Detect that and bounce the default to the user's chosen real device.
    private func recoverFromCrashedSession() {
        let current = SystemAudio.defaultOutputDevice()
        guard let mac = SystemAudio.macStereoFixDeviceID(), current == mac else { return }
        if let uid = selectedOutputUID,
           let target = availableOutputs.first(where: { $0.uid == uid }) {
            SystemAudio.setDefaultOutputDevice(target.id)
        } else if let first = availableOutputs.first {
            SystemAudio.setDefaultOutputDevice(first.id)
        }
    }

    private func installTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // willTerminate has a very brief window before the app dies, so
            // we must run synchronously. We're on the main queue already
            // (queue: .main above), so it's safe to assume the main actor.
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if self.isOn { self.turnOff() }
            }
        }
    }

    // MARK: - Device list

    func refreshDevices() {
        var devices = SystemAudio.allOutputDevices()
        // Hide the MacStereoFix device itself from the picker.
        devices.removeAll { $0.uid == SystemAudio.macStereoFixUID }
        self.availableOutputs = devices
        self.driverInstalled = DriverManager.isInstalled()

        let selectedStillPresent = devices.contains(where: { $0.uid == selectedOutputUID })

        // If no valid selection, pick a new default.
        if !selectedStillPresent {
            let currentDefault = SystemAudio.defaultOutputDevice()
            if let match = devices.first(where: { $0.id == currentDefault }) {
                selectedOutputUID = match.uid
            } else if let first = devices.first {
                selectedOutputUID = first.uid
            }
        }

        // Auto-failover: if we're running and the selected device just
        // disconnected (e.g. AirPods taken off), switch to the new selection.
        if isOn && !selectedStillPresent {
            if let uid = selectedOutputUID {
                switchOutputDeviceLive(to: uid)
            } else {
                // No devices left at all — turn off gracefully.
                turnOff()
                lastError = "Output device disconnected and no alternatives found."
            }
        }

        refreshOutputVolumeFromDevice()
    }

    /// Pull the current volume off the selected device into the slider value.
    private func refreshOutputVolumeFromDevice() {
        guard let uid = selectedOutputUID,
              let dev = availableOutputs.first(where: { $0.uid == uid }) else {
            outputVolumeAvailable = false
            return
        }
        if let v = SystemAudio.deviceVolume(dev.id) {
            suppressVolumeWriteback = true
            outputVolume = v
            suppressVolumeWriteback = false
            outputVolumeAvailable = true
        } else {
            outputVolumeAvailable = false
        }
    }

    private func installDeviceListListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block)
    }

    // MARK: - Toggle / routing

    func toggle() {
        if isOn {
            turnOff()
        } else {
            turnOn()
        }
    }

    func turnOn() {
        guard !isOn else { return }
        lastError = nil
        guard let outputUID = selectedOutputUID,
              let target = availableOutputs.first(where: { $0.uid == outputUID }) else {
            lastError = "No output device selected."
            return
        }
        guard DriverManager.isInstalled() else {
            lastError = "MacStereoFix driver not installed."
            return
        }
        guard let macStereoFix = SystemAudio.macStereoFixDeviceID() else {
            lastError = "MacStereoFix device missing — try Reinstall Driver."
            return
        }
        do {
            try router.start(outputDevice: target.id)
        } catch {
            lastError = error.localizedDescription
            return
        }
        // Wire the virtual device's volume control to the real output so
        // the hardware volume keys adjust the real device while running.
        // Must happen BEFORE hijacking the default so the first key press
        // (which usually happens after the default change) finds us ready.
        setupVirtualVolumeBridge(macStereoFix: macStereoFix, realDeviceID: target.id)

        // Hijack the system default output to MacStereoFix so games go through us.
        previousDefaultDevice = SystemAudio.defaultOutputDevice()
        if previousDefaultDevice == macStereoFix {
            // Avoid restoring back to ourselves on Off; pick the user's chosen
            // real device as the "previous" so toggling Off restores cleanly.
            previousDefaultDevice = target.id
        }
        if !SystemAudio.setDefaultOutputDevice(macStereoFix) {
            tearDownVirtualVolumeBridge()
            router.stop()
            lastError = "Could not set MacStereoFix as default output device."
            return
        }
        isOn = true
        UserDefaults.standard.set(true, forKey: "wasOn")
    }

    func turnOff() {
        if previousDefaultDevice != 0 {
            SystemAudio.setDefaultOutputDevice(previousDefaultDevice)
        }
        tearDownVirtualVolumeBridge()
        router.stop()
        isOn = false
        UserDefaults.standard.set(false, forKey: "wasOn")
    }

    /// Switch the real output device while the pipeline stays active.
    /// The system default (MacStereoFix) is untouched — only the render side
    /// is rebuilt, so there's no audible gap or device-switch glitch.
    func switchOutputDeviceLive(to uid: String) {
        guard isOn else { return }
        guard let target = availableOutputs.first(where: { $0.uid == uid }) else {
            lastError = "Device not found."
            return
        }
        do {
            try router.switchOutputDevice(target.id)
            // Update previousDefaultDevice so Off restores to the new choice.
            previousDefaultDevice = target.id
            // Re-seed the virtual control from the new real device so the
            // next volume key press steps from the right baseline.
            reseedVirtualVolumeBridge(realDeviceID: target.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Driver install / uninstall

    func installDriver() {
        lastError = nil
        if let err = DriverManager.installDriver() {
            lastError = err
        }
        // Give coreaudiod a moment to come back, then re-scan.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshDevices()
        }
    }

    func uninstallDriver() {
        if isOn { turnOff() }
        lastError = nil
        if let err = DriverManager.uninstallDriver() {
            lastError = err
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshDevices()
        }
    }

    // MARK: - Virtual volume bridge

    /// Discover MacStereoFix's output volume control, seed it with the
    /// real device's current volume, and install a listener so hardware
    /// volume-key presses mirror onto the real device. Called by turnOn.
    private func setupVirtualVolumeBridge(macStereoFix: AudioDeviceID, realDeviceID: AudioDeviceID) {
        guard let ctl = SystemAudio.outputVolumeControlID(for: macStereoFix) else {
            // Driver predates the volume control — slider still works,
            // hardware volume keys just won't. Not an error.
            virtualVolumeControlID = nil
            virtualVolumeListenerBlock = nil
            return
        }
        virtualVolumeControlID = ctl

        // Seed the control with the real device's current volume so the
        // first key press produces a normal-sized step rather than a jump
        // from whatever stale value the driver last remembered.
        if let realVol = SystemAudio.deviceVolume(realDeviceID) {
            SystemAudio.setControlScalarValue(ctl, realVol)
        }

        // Install the listener. AudioObjectAddPropertyListenerBlock will
        // deliver the callback on the queue we pass, so we're already on
        // main when the handler runs.
        let block = SystemAudio.installControlScalarListener(
            on: ctl,
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.handleVirtualVolumeChange()
            }
        }
        virtualVolumeListenerBlock = block
    }

    /// Remove the listener and clear cached state. Called by turnOff.
    private func tearDownVirtualVolumeBridge() {
        if let ctl = virtualVolumeControlID, let block = virtualVolumeListenerBlock {
            SystemAudio.removeControlScalarListener(on: ctl, queue: .main, block: block)
        }
        virtualVolumeControlID = nil
        virtualVolumeListenerBlock = nil
    }

    /// When the real output device changes mid-session, re-read its
    /// current volume and push it into the virtual control so the next
    /// key press steps from the right baseline.
    private func reseedVirtualVolumeBridge(realDeviceID: AudioDeviceID) {
        guard let ctl = virtualVolumeControlID else { return }
        guard let realVol = SystemAudio.deviceVolume(realDeviceID) else { return }
        SystemAudio.setControlScalarValue(ctl, realVol)
    }

    /// Fired when macOS writes a new value to the virtual device's output
    /// volume control — usually because the user pressed a hardware volume
    /// key. Mirror the new value to the real device and update the slider.
    private func handleVirtualVolumeChange() {
        guard let ctl = virtualVolumeControlID else { return }
        guard let newValue = SystemAudio.controlScalarValue(ctl) else { return }
        if let uid = selectedOutputUID,
           let dev = availableOutputs.first(where: { $0.uid == uid }) {
            SystemAudio.setDeviceVolume(dev.id, newValue)
        }
        // Update the slider, suppressing the didSet so it doesn't write
        // back to the real device or the virtual control again.
        suppressVolumeWriteback = true
        outputVolume = newValue
        suppressVolumeWriteback = false
    }
}
