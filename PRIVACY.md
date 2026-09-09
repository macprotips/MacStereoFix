# Privacy

MacStereoFix processes audio routed to its virtual output while Force Stereo is
on. That audio can include private conversations, notifications, or other app
content. It passes through temporary buffers in memory to create stereo output.
The app has no recording-to-file feature, analytics, advertising, network client,
or automatic updater. It does not transmit audio or select a physical microphone.

macOS requires microphone permission to read the virtual input. This permission
is broader than the app's intended use: the implementation explicitly binds
capture to the MacStereoFix device before starting it. Denial does not enable
routing. Revoke permission in System Settings → Privacy & Security → Microphone.

The virtual input is a system audio device. Other local applications with the
necessary macOS audio-input permission may also select it. It is not an encrypted
or exclusive channel for private audio. Turn Force Stereo off when it is not needed.

The app saves the selected output UID, dialogue boost, routing volume and a
recovery output UID in its own preferences. It saves no audio history. The small
recovery helper receives the fallback device UID, waits for the app's pipe to
close, and attempts to restore output. It runs as the same user, has no elevated
privileges, and exits after recovery or normal disarming.

Administrator authorization is used only for the explicit driver install and
remove actions. Those actions modify MacStereoFix's driver under
`/Library/Audio/Plug-Ins/HAL` and restart CoreAudio. They do not change SIP,
Gatekeeper, login items, or the user's hardware volume. macOS and Apple's signing
and notarization services may perform their own security checks independently.

To remove local preferences after uninstalling, use
`defaults delete com.macstereofix.app` in Terminal. App removal alone may leave
preferences behind, as with other macOS applications.
