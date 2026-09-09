import Foundation

/// A child owns the read end of a pipe. App termination (including SIGKILL)
/// closes the write end, waking it to restore the output without a login item.
final class AudioRecovery {
    private var process: Process?
    private var input: FileHandle?

    var isRunning: Bool { process?.isRunning == true }

    func arm(preferredUID: String?) throws {
        disarm()
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "MacStereoFixRecovery") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let child = Process()
        let pipe = Pipe()
        child.executableURL = executable
        child.arguments = [preferredUID ?? ""]
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = child
        input = pipe.fileHandleForWriting
        // Process.run returns only after a successful exec; EOF is retained if
        // the parent exits before the child starts reading.
    }

    func disarm() {
        if let input {
            try? input.write(contentsOf: Data("disarm\n".utf8))
            try? input.close()
        }
        input = nil
        process = nil
    }

    deinit {
        // No disarm here: unexpected owner destruction must trigger recovery.
        try? input?.close()
    }
}
