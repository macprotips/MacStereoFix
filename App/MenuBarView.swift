// MenuBarView.swift
//
// The dropdown shown when the user clicks the menu bar icon. Big toggle, an
// output device picker, a dialogue boost slider, and driver install controls.

import SwiftUI

struct MenuBarView: View {

    @EnvironmentObject var state: AppState

    /// Shown in the footer. Pulled from Info.plist so bumping the version
    /// there is enough — no source change needed.
    private static let appVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if !state.driverInstalled {
                driverNotInstalledSection
            } else {
                toggleSection
                Divider()
                outputPickerSection
                if state.outputVolumeAvailable {
                    volumeSection
                }
                Divider()
                advancedSection
            }
            if let error = state.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.isOn ? "hifispeaker.2.fill" : "hifispeaker.2")
                .font(.title2)
                .foregroundStyle(state.isOn ? .green : .secondary)
            Text("MacStereoFix")
                .font(.headline)
            Spacer()
        }
    }

    private var driverNotInstalledSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Driver not installed")
                .font(.subheadline).bold()
            Text("MacStereoFix needs to install a small audio driver. You'll be asked for your password once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Install Driver") {
                state.installDriver()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var toggleSection: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { state.isOn },
                set: { _ in state.toggle() }
            )) {
                Text("Force Stereo")
                    .font(.subheadline).bold()
            }
            .toggleStyle(.switch)
        }
    }

    private var outputPickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Send stereo to")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { state.selectedOutputUID ?? "" },
                set: { newUID in
                    let uid = newUID.isEmpty ? nil : newUID
                    state.selectedOutputUID = uid
                    if state.isOn, let uid {
                        state.switchOutputDeviceLive(to: uid)
                    }
                }
            )) {
                ForEach(state.availableOutputs) { dev in
                    Text(dev.name).tag(dev.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Volume")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((state.outputVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $state.outputVolume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 6) {
                Button("Reinstall Driver") { state.installDriver() }
                Button("Uninstall Driver", role: .destructive) { state.uninstallDriver() }
                Button("Refresh Devices") { state.refreshDevices() }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            Text("v\(Self.appVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") {
                if state.isOn { state.turnOff() }
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
    }
}
