import Foundation
// The recovery binary uses this double in tests; no CoreAudio calls are linked.
enum SystemAudio {
    static func restoreOutput(preferredUID: String?) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MSF_RECOVERY_TEST_LOG"] else { fatalError("Missing test log") }
        try! Data((preferredUID ?? "nil").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return true
    }
}
