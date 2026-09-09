import Foundation

enum DriverManager {
    static let driverInstallPath = "/Library/Audio/Plug-Ins/HAL/MacStereoFix.driver"
    // Pin privileged installation to this project's Developer ID, not any signed bundle.
    static let signingRequirement = #"identifier "com.macstereofix.driver" and anchor apple generic and certificate leaf[subject.OU] = "MD83L42DNL" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#

    static func isInstalled() -> Bool {
        guard let bundled = bundledDriverPath(),
              let expected = version(at: bundled), expected == version(at: driverInstallPath) else { return false }
        return SystemAudio.macStereoFixDriverVersion() == expected
    }

    private static func version(at path: String) -> String? {
        // Read the plist directly: Bundle caches metadata across reinstalls.
        let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    private static func bundledDriverPath() -> String? {
        Bundle.main.resourceURL?.appendingPathComponent("MacStereoFix.driver").path
    }

    static func installDriver() -> String? {
        guard let source = bundledDriverPath() else { return "Bundled driver not found." }
        // Generated Swift constants are sealed in the app's signed executable.
        let shell = "set -- \(shellQuote(source)) \(shellQuote(signingRequirement))\n" + InstallerScripts.install
        return runPrivileged(shell: shell, failureLabel: "Installation failed.")
    }

    static func uninstallDriver() -> String? {
        runPrivileged(shell: InstallerScripts.uninstall, failureLabel: "Removal failed.")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScript(shell: String) -> String {
        // A fixed shell and a single quoted script argument prevent any path
        // (including spaces, quotes and newlines) from becoming executable code.
        let command = "/bin/bash -c " + shellQuote(shell)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    private static func runPrivileged(shell: String, failureLabel: String) -> String? {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(shell: shell)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            // Drain before waiting so a large error cannot fill the pipe and deadlock.
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.flatMap { $0.isEmpty ? nil : $0 } ?? failureLabel
        } catch { return "\(failureLabel) \(error.localizedDescription)" }
    }
}
