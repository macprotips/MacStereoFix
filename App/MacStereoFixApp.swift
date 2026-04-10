// MacStereoFixApp.swift
//
// Menu bar app entry point. Uses SwiftUI's MenuBarExtra (macOS 13+) so the
// app lives entirely in the status bar — no dock icon, no main window.

import SwiftUI

@main
struct MacStereoFixApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.isOn ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuBarExtraStyle(.window)
    }
}
