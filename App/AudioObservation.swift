import CoreAudio
import Foundation

/// Owns the exact block and queue required to remove a CoreAudio listener.
final class AudioObservation {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
          selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) {
        self.object = object
        address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        block = { _, _ in MainActor.assumeIsolated { handler() } }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
    }

    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, .main, block) }
}
