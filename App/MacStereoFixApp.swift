// MacStereoFixApp.swift
//
// Menu bar app entry point. Uses SwiftUI's MenuBarExtra (macOS 13+) so the
// app lives entirely in the status bar — no dock icon, no main window.

import SwiftUI

@main
struct MacStereoFixApp: App {
    @StateObject private var state = AppState()

    init() {
        // Hold the lock until process exit. O_CLOEXEC keeps the recovery helper
        // from inheriting it; O_NOFOLLOW prevents following an unexpected link.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("com.macstereofix.app.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            let alert = NSAlert()
            alert.messageText = "MacStereoFix is already open or couldn't acquire its session lock."
            alert.informativeText = "Use the speaker icon in your menu bar. If no copy is running, restart your Mac and try again."
            alert.runModal()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.isOn ? "hifispeaker.2.fill" : "hifispeaker.2")
                .accessibilityLabel(state.isOn ? "MacStereoFix, Force Stereo on" : "MacStereoFix, Force Stereo off")
        }
        .menuBarExtraStyle(.window)
    }
}
