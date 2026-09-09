# Release checklist

Status for 1.3.0: **not signed off for public release**. Passing automated checks
is necessary; it does not replace tests through the actual macOS audio system.
Record the tested commit SHA, app/driver build number, macOS version, Mac model,
output device and result for each hardware test. Re-test affected cases after a
code change. Never reuse a checklist from an older binary.

## Automated gates

- [ ] Both GitHub Actions jobs pass on the exact commit (Apple Silicon and Intel).
- [ ] A clean local `./build.sh && ./check.sh` passes.
- [ ] The new app, recovery executable and driver contain both architectures.
- [ ] Source, bundled driver, installed driver and loaded driver versions agree.

## Fresh installation and privacy

Use a spare/test Mac or a controlled session with calls and recordings finished.
Keep System Settings → Sound → Output available for immediate recovery. Begin
with the physical device at a low volume. The installer needs a local administrator.

- [ ] Fresh signed build launches using normal Gatekeeper settings.
- [ ] Install succeeds; cancelling authorization leaves the old driver intact.
- [ ] New install and upgrade from v1.2 both load the current driver.
- [ ] Deny microphone access: routing stays off and normal sound continues.
- [ ] Grant access and start: the selected physical output receives stereo.
- [ ] Physical microphone/default input remains unchanged.
- [ ] No unknown network activity, audio files, login items or elevated helper persist.

## Sound and recovery

- [ ] Stereo left/right and 5.1/7.1 channel-identification clips route correctly.
- [ ] Center dialogue is present; LFE omission and high-boost clipping are understood.
- [ ] Volume keys, mute key, UI volume and mute work, including a fixed-volume output.
- [ ] Turning Off returns to the device's normal volume; channel balance is unchanged.
- [ ] Repeated On/Off, Quit, relaunch and a second app instance behave correctly.
- [ ] Keyboard and VoiceOver can operate the toggle, picker, sliders, mute and recovery instructions.
- [ ] Force Quit while on restores normal output without relaunching the app.
- [ ] Change output in Sound settings: routing stops and preserves the new selection.
- [ ] Switch outputs; unplug the active one; disconnect all available outputs.
- [ ] Reconnect, sleep/wake, logout/login, reboot, and a CoreAudio restart recover.
- [ ] Reinstall and uninstall while on first stop routing and restore output.
- [ ] Run a representative game for at least 60 minutes: no accumulating latency,
      repeated dropouts, clicks, excessive CPU, or unexpected loudness changes.

## Compatibility matrix

Minimum advertised OS remains macOS 13. Do not claim a version/device tested
unless a physical test was actually performed. If coverage is unavailable,
restrict the advertised support rather than assuming it works.

| Mac / OS | Built-in speakers | Wired / USB | Bluetooth stereo | 44.1 kHz | 48 kHz | 96/192 kHz |
|---|---|---|---|---|---|---|
| Apple Silicon / macOS 13 | Pending | Pending | Pending | Pending | Pending | Pending |
| Intel / macOS 13 | Pending | Pending | Pending | Pending | Pending | Pending |
| Apple Silicon / current public macOS | Pending | Pending | Pending | Pending | Pending | Pending |
| Intel / supported public macOS | Pending | Pending | Pending | Pending | Pending | Pending |

Bluetooth mono call modes, virtual/aggregate destinations and per-app-selected
outputs are intentionally outside the supported routing path.

## Final artifact

- [ ] Record the hardware sign-off for the exact commit above.
- [ ] Run `release.sh` with Developer ID, the saved notarization profile and
      `RELEASE_TESTED_COMMIT` equal to that full commit SHA.
- [ ] Apple reports Accepted; the ticket is stapled and Gatekeeper accepts the app.
- [ ] Download the final ZIP on a clean Mac and open it under normal security settings.
- [ ] Check the SHA-256 checksum against the published file.
- [ ] Publish accurate release notes and the matching source; no security-bypass instructions.

The release script deliberately refuses to package an ad-hoc, unnotarized, dirty,
or unacknowledged source revision as a release. A signing certificate alone does
not meet these gates. Apple's notarization is an automated malicious-content and
signing check, not App Review or a guarantee of bug-free behavior.
[Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
