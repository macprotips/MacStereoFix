// DriverManager.swift
//
// Checks whether the MacStereoFix.driver bundle is installed in the system
// HAL plug-in directory, and provides an installer that copies the bundled
// driver in via an authenticated AppleScript "do shell script with
// administrator privileges" call. Reloads coreaudiod after install so the
// device shows up immediately.

import Foundation

enum DriverManager {

    // MARK: - Paths

    static let driverInstallPath = "/Library/Audio/Plug-Ins/HAL/MacStereoFix.driver"

    // MARK: - Status

    /// True if the driver bundle exists on disk AND the device is registered.
    static func isInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: driverInstallPath)
            && SystemAudio.isInstalled()
    }

    /// Returns the path to the bundled driver inside our app's Resources, or
    /// nil if it's missing (which should never happen in a properly built app).
    private static func bundledDriverPath() -> String? {
        guard let resPath = Bundle.main.resourcePath else { return nil }
        let candidate = (resPath as NSString).appendingPathComponent("MacStereoFix.driver")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    // MARK: - Install / uninstall

    /// Install (or reinstall) the driver. Prompts the user for an admin
    /// password via the standard macOS authentication dialog. Returns nil on
    /// success or an error message on failure.
    static func installDriver() -> String? {
        guard let src = bundledDriverPath() else {
            return "Bundled driver not found inside MacStereoFix.app/Contents/Resources."
        }
        let escapedSrc = shellEscape(src)
        let escapedDst = shellEscape(driverInstallPath)
        let shell = """
        mkdir -p '/Library/Audio/Plug-Ins/HAL' && \
        rm -rf '\(escapedDst)' && \
        cp -R '\(escapedSrc)' '\(escapedDst)' && \
        xattr -dr com.apple.quarantine '\(escapedDst)' 2>/dev/null; \
        chown -R root:wheel '\(escapedDst)' && \
        killall coreaudiod 2>/dev/null || true
        """
        return runPrivileged(shell: shell, failureLabel: "Install failed.")
    }

    /// Uninstall the driver. Same admin prompt flow.
    static func uninstallDriver() -> String? {
        let escapedDst = shellEscape(driverInstallPath)
        let shell = """
        rm -rf '\(escapedDst)' && (killall coreaudiod 2>/dev/null || true)
        """
        return runPrivileged(shell: shell, failureLabel: "Uninstall failed.")
    }

    // MARK: - Privileged shell helper

    /// Wrap `shell` in a `do shell script ... with administrator privileges`
    /// AppleScript and run it. Returns nil on success or an error message.
    private static func runPrivileged(shell: String, failureLabel: String) -> String? {
        // Escape the shell string for embedding inside a double-quoted
        // AppleScript literal: backslashes first, then double quotes.
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "\(escaped)" with administrator privileges
        """
        guard let scriptObj = NSAppleScript(source: appleScript) else {
            return "Could not create AppleScript."
        }
        var errorDict: NSDictionary?
        _ = scriptObj.executeAndReturnError(&errorDict)
        if let err = errorDict {
            return (err["NSAppleScriptErrorMessage"] as? String) ?? failureLabel
        }
        return nil
    }

    /// Single-quote-escape a path so it's safe to embed inside a `'...'` shell
    /// literal (closes the quote, inserts an escaped quote, reopens).
    private static func shellEscape(_ s: String) -> String {
        return s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
