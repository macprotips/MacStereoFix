import Foundation

enum SystemAudio { static func macStereoFixDriverVersion() -> String? { nil } }
@main
struct QuoteTests {
    static func main() throws {
        for path in ["", "/Applications/MacStereoFix.app", "spaces and 'single' and \"double\" quotes",
                     "literal $(echo INJECTED); `echo BAD`; $HOME & | > < ! \\ backslash",
                     "new\nline\rreturn\ttab", "日本語 🎧"] {
            let shell = "printf '%s' " + DriverManager.shellQuote(path)
            let script = DriverManager.appleScript(shell: shell)
                .replacingOccurrences(of: " with administrator privileges", with: "")
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            assert(process.terminationStatus == 0)
            // do shell script normalizes LF to CR by default; osascript prints
            // the result plus a trailing LF. Compare that documented behavior.
            let actual = String(data: data, encoding: .utf8)!
            let expected = path.replacingOccurrences(of: "\n", with: "\r")
            assert(actual == expected + "\n", "Quoting changed a literal path: \(actual.debugDescription)")
        }
        print("Shell + AppleScript quoting passed for spaces, quotes, metacharacters, newlines and Unicode (no administrator access)")
    }
}
