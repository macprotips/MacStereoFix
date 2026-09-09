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
                volumeSection
                dialogueSection
                Divider()
                advancedSection
            }
            if let error = state.lastError {
                Divider()
                ScrollView {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            if let message = state.statusMessage {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if state.isBusy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
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
            Text("Driver installation required")
                .font(.subheadline).bold()
            Text("Install or update the audio driver. macOS will ask for an administrator password. All Mac audio will briefly stop while the driver loads; finish calls and recordings first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Install Driver") {
                state.installDriver()
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isBusy)
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
            .disabled(state.isBusy || state.availableOutputs.isEmpty)
        }
    }

    private var outputPickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Send stereo to")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Send stereo to", selection: Binding(
                get: { state.selectedOutputUID ?? "" },
                set: { newUID in
                    state.selectOutput(newUID)
                }
            )) {
                ForEach(state.availableOutputs) { dev in
                    Text(dev.name).tag(dev.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(state.isBusy || state.availableOutputs.isEmpty)
            if state.availableOutputs.isEmpty {
                Text("Connect stereo speakers or headphones. Virtual and aggregate outputs aren't supported.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
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
                Slider(value: $state.outputVolume, in: 0...1) { Text("Routing volume") }
                    .labelsHidden()
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Controls routed audio. Turning Off returns to your device's normal volume.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Mute routed audio", isOn: $state.isMuted).font(.caption)
        }
        .padding(.top, 8)
    }

    private var dialogueSection: some View {
        VStack(alignment: .leading) {
            Text("Dialogue boost: +\(state.dialogueBoostDB, specifier: "%.0f") dB")
                .font(.caption)
            Slider(value: $state.dialogueBoostDB, in: 0...9, step: 1) { Text("Dialogue boost") }
                .labelsHidden()
            Text("Start with a low listening volume. More boost can distort loud scenes.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 6) {
                Button("Reinstall Driver") { state.installDriver() }
                Button("Uninstall Driver", role: .destructive) { state.uninstallDriver() }
                Button("Refresh Devices") { state.refreshDevices() }
            }
            .padding(.top, 4)
            .disabled(state.isBusy)
            Text("Installing or removing the driver briefly interrupts all Mac audio.")
                .font(.caption2).fixedSize(horizontal: false, vertical: true)
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
            .disabled(state.isBusy)
        }
    }
}
