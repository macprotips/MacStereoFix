import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark ? .cyan : Color(red: 0, green: 0.38, blue: 0.43)
    }
    private var mutedColor: Color {
        colorScheme == .dark ? .orange : Color(red: 0.6, green: 0.29, blue: 0)
    }
    private var errorColor: Color {
        colorScheme == .dark ? .red : Color(red: 0.7, green: 0.12, blue: 0.12)
    }

    private static let appVersion =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"

    private var isSilent: Bool { state.isMuted || state.outputVolume == 0 }
    private var statusColor: Color {
        state.isOn ? (isSilent ? mutedColor : accent) : .secondary
    }
    private var statusLabel: String {
        if state.isBusy { return "Working…" }
        return state.isOn ? (isSilent ? "Muted" : "On") : "Off"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if state.driverInstalled {
                    routingSection
                    VStack(alignment: .leading, spacing: 14) {
                        outputSection
                        Divider()
                        volumeSection
                        Divider()
                        dialogueSection
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    setupSection
                }
                messages
                driverSection
                Divider()
                footer
            }
            .padding(18)
        }
        .frame(width: 360)
        .frame(maxHeight: min(680, (NSScreen.main?.visibleFrame.height ?? 768) - 40))
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 42, height: 42)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("MacStereoFix").font(.system(size: 17, weight: .semibold))
                Text("Surround sound, in stereo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Force Stereo").font(.headline)
                Spacer()
                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(statusColor.opacity(0.1), in: Capsule())
                Toggle("Force Stereo", isOn: Binding(
                    get: { state.isOn }, set: { _ in state.toggle() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(state.isBusy || state.availableOutputs.isEmpty)
                .help("Mix surround audio into your selected stereo output")
            }
            Text(state.isBusy ? (state.statusMessage ?? "Preparing audio. Check for a macOS permission prompt.")
                 : state.isOn
                 ? (state.isMuted ? "Audio is muted. Tap the speaker button to listen again."
                    : isSilent ? "Volume is at 0%. Raise it to hear your stereo mix."
                    : "Your stereo mix is playing through the output below.")
                 : "Turn on to hear surround channels through two speakers or headphones.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(statusColor.opacity(state.isOn ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Stereo output", systemImage: "headphones")
                .font(.subheadline.weight(.medium))
            Picker("Stereo output", selection: Binding(
                get: { state.selectedOutputUID ?? "" }, set: { state.selectOutput($0) }
            )) {
                if state.selectedOutputUID == nil { Text("No output connected").tag("") }
                ForEach(state.availableOutputs) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(state.availableOutputs.first { $0.uid == state.selectedOutputUID }?.name ?? "Connect stereo speakers or headphones")
            .disabled(state.isBusy || state.availableOutputs.isEmpty)
            if state.availableOutputs.isEmpty {
                Text("Connect stereo speakers or headphones, then refresh. Virtual and aggregate outputs aren't supported.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh outputs") { state.refreshDevices() }
                    .controlSize(.small).disabled(state.isBusy)
            }
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Volume").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((state.outputVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Toggle(isOn: $state.isMuted) {
                    Label("Mute routed audio", systemImage: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .labelStyle(.iconOnly)
                .toggleStyle(.button)
                .controlSize(.small)
                .help(state.isMuted ? "Unmute routed audio" : "Mute routed audio")
                Slider(value: $state.outputVolume, in: 0...1) { Text("Routing volume") }
                    .labelsHidden()
                    .accessibilityValue("\(Int((state.outputVolume * 100).rounded())) percent")
            }
            .disabled(state.isBusy)
            Text("Applies while Force Stereo is on. Off returns to your device’s normal volume.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dialogueSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Dialogue boost").font(.subheadline.weight(.medium))
                Spacer()
                Text("+\(Int(state.dialogueBoostDB)) dB")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $state.dialogueBoostDB, in: 0...9, step: 1) { Text("Dialogue boost") }
                .labelsHidden()
                .accessibilityValue("\(Int(state.dialogueBoostDB)) decibels")
                .disabled(state.isBusy)
            Text("Raises the center channel in surround audio. Start at a low volume; high boost can distort loud scenes.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up stereo audio").font(.title3.weight(.semibold))
            Text("Install the audio driver to bring dialogue and surround effects into your stereo mix.")
                .font(.subheadline).foregroundStyle(.secondary)
            Label {
                Text("All Mac audio will briefly stop during installation. Finish calls and recordings first.")
            } icon: {
                Image(systemName: "speaker.wave.2.bubble")
            }
            .font(.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Button(action: state.installDriver) {
                Text("Install Audio Driver…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.isBusy)
            Text("macOS asks for an administrator password. Microphone access is requested when you first turn on Force Stereo to read the virtual audio device.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var messages: some View {
        if let error = state.lastError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(errorColor)
                ScrollView {
                    Text(error)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                Button("Open System Settings…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        if state.isBusy || state.statusMessage != nil {
            HStack(alignment: .top, spacing: 8) {
                if state.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                } else {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                Text(state.statusMessage ?? "Preparing audio…")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var driverSection: some View {
        DisclosureGroup("Driver & help") {
            VStack(alignment: .leading, spacing: 10) {
                Label(state.driverInstalled ? "Audio driver ready" : "Current audio driver needed",
                      systemImage: state.driverInstalled ? "checkmark.circle" : "info.circle")
                HStack {
                    Button("Reinstall…", action: state.installDriver)
                    Button("Uninstall…", role: .destructive, action: state.uninstallDriver)
                }
                .controlSize(.small).disabled(state.isBusy)
                Text("Installing or removing the driver briefly interrupts all Mac audio.")
                    .foregroundStyle(.secondary)
                Divider()
                Text("Audio is processed on this Mac. No recordings or uploads. Microphone permission lets macOS capture the virtual device; your physical microphone is not selected.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            Text("v\(Self.appVersion)").foregroundStyle(.secondary)
            Spacer()
            Button("Refresh", action: state.refreshDevices)
                .help("Refresh audio outputs and driver status")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isBusy)
            Button("Quit") {
                if state.isOn { state.turnOff() }
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .disabled(state.isBusy)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}
