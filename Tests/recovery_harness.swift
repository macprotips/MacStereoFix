import Foundation
@main
struct RecoveryHarness {
    static func main() throws {
        let recovery = AudioRecovery()
        try recovery.arm(preferredUID: "test-headphones")
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        let command = readLine()
        if command == "disarm" { recovery.disarm() }
        // Otherwise closing the owner (or SIGKILL from the test) triggers recovery.
    }
}
