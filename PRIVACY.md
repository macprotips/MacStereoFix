# Privacy

## Audio

While Force Stereo is on, MacStereoFix reads audio sent to its virtual device
and mixes it in memory. That audio may include conversations or other private
content from apps using the default output.

The app does not save recordings or send audio over the network. It has no
analytics, advertising, or automatic updater.

## Microphone permission

macOS requires microphone permission to read the virtual audio input.
MacStereoFix selects its own virtual device for capture, not your physical
microphone. If permission is denied, routing stays off.

You can revoke access in **System Settings → Privacy & Security → Microphone**.

The virtual input is a system audio device. Other local apps with the necessary
audio permission may also select it. Turn Force Stereo off when you no longer
need it.

## Saved settings

The app saves the selected output device, volume, dialogue boost, and the output
to restore after a failure. These settings stay in the app's local preferences.
It does not keep an audio history.

A recovery helper receives the fallback output identifier and watches for the
app to close. It runs as your user account and exits after recovery or a normal
shutdown. It has no administrator privileges or login item.

## Administrator access

Installing or removing the driver requires administrator approval. These actions
modify MacStereoFix's driver in `/Library/Audio/Plug-Ins/HAL` and restart CoreAudio.
They do not change hardware volume, Gatekeeper, SIP, or login items.

## Removing saved settings

After uninstalling, preferences can be removed in Terminal with:

```sh
defaults delete com.macstereofix.app
```

Deleting the app alone may leave these preferences on your Mac.
