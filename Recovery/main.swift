import Foundation

// This helper runs as the logged-in user. It changes only an output still set
// to MacStereoFix, and exits as soon as the owning app closes its pipe.
let preferredUID = CommandLine.arguments.dropFirst().first
var disarmed = false
while let line = readLine() {
    if line == "disarm" { disarmed = true }
}
if !disarmed {
    // CoreAudio may be restarting at the same time the app exits.
    for _ in 0..<25 {
        if SystemAudio.restoreOutput(preferredUID: preferredUID) { break }
        Thread.sleep(forTimeInterval: 0.2)
    }
}
