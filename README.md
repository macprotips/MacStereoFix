# MacStereoFix

A Mac menu bar app that mixes surround audio into stereo. It can help when
voices or sound effects are missing in games played through stereo speakers
or headphones.

[Downloads](https://github.com/macprotips/MacStereoFix/releases) ·
[Changelog](CHANGELOG.md) · [Report a problem](https://github.com/macprotips/MacStereoFix/issues)

**Version 1.3 is in development.** The current v1.2 download does not include
the driver and recovery fixes described below. Live audio testing and Apple
notarization for 1.3 are still pending.

<table><tr>
<td><img src="docs/images/stereo-light.png" width="360" alt="MacStereoFix in light mode"></td>
<td><img src="docs/images/stereo-dark.png" width="360" alt="MacStereoFix in dark mode"></td>
</tr></table>

Interface previews for 1.3, shown with a sample output.

## Using MacStereoFix

1. Unzip a release and move `MacStereoFix.app` to Applications.
2. Open the app and click its speaker icon in the menu bar.
3. Click **Install Audio Driver…** and approve the macOS administrator prompt.
   Installation briefly interrupts all Mac audio, so finish calls and recordings first.
4. Choose your speakers or headphones, then turn **Force Stereo** on.
5. Allow microphone access when macOS asks. This lets the app read its virtual
   audio device; it does not select your physical microphone.

Start with your device at a low listening volume. **Volume** and **Mute** affect
routed audio. Turning Force Stereo off returns to your device's normal volume.

Dialogue is included in the standard stereo mix. An optional **Dialogue boost**
is available under **Advanced** and is off by default.

The app starts off each time you open it. Sleep, device disconnection, a routing
error, or a manual output change stops routing. Select your output and turn it
on again when you're ready.

## How it works

MacStereoFix installs a virtual CoreAudio device and mixes its surround channels
into two output channels. Apps that use the macOS default output follow this
route; apps that choose their own output may bypass it. System alerts and
protected media may behave differently.

The destination must have at least two output channels. Virtual and aggregate
outputs and Bluetooth mono call modes are not supported. The app handles PCM
audio; it does not decode Dolby or DTS bitstreams.

Audio is processed in memory on your Mac. There are no recordings, uploads,
analytics, or ads. See [Privacy](PRIVACY.md) for permission and storage details.

## If sound stops

Open **System Settings → Sound → Output** and choose your normal speakers or
headphones. Do not select MacStereoFix manually while its app is off.

- **Permission denied:** allow MacStereoFix in **Privacy & Security → Microphone**.
- **Driver update has not loaded:** restart the Mac.
- **Bluetooth is in call mode:** end the call or choose another stereo output.
- **macOS cannot verify the app:** download a signed, notarized release. Keep
  Gatekeeper and other macOS security settings enabled.

## Uninstall

Choose **Advanced → Uninstall…**, then move the app to the Trash. Removing the
driver requires administrator approval and briefly interrupts Mac audio.

## Development

Builds target macOS 13 and include Apple Silicon and Intel binaries. OS and device
coverage is tracked in the [release checklist](docs/RELEASE_CHECKLIST.md).

Build instructions, tests, and release commands are in
[Development](docs/DEVELOPMENT.md). Security issues can be
[reported privately](SECURITY.md).

[Usage terms](LICENSE) · [Apple sample attribution](ThirdParty/README.md)
