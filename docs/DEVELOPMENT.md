# Development

## Build

Use Xcode 15 or newer, or the matching Command Line Tools, with Swift 5.9+ and
Python 3. Both Apple Silicon and Intel binaries target macOS 13.

```sh
./build.sh
./check.sh
```

The app and bundled driver are written to `build/`. Without `SIGN_IDENTITY`,
builds use ad-hoc signatures and are for local development. The in-app installer
requires the project's Developer ID. To test your own ad-hoc build locally:

```sh
sudo ./install.sh --allow-adhoc
```

Installation restarts CoreAudio and briefly interrupts all Mac audio. Select a
normal output and quit the app before running `sudo ./uninstall.sh`.

## Tests

`check.sh` covers driver property bounds, concurrent audio buffers, channel
mixing, sample-rate conversion, routing failures, installer rollback, quoting,
and crash recovery. It runs AddressSanitizer, UndefinedBehaviorSanitizer,
ThreadSanitizer, static analysis, and bundle checks.

Tests use temporary directories and substitutes for system-changing operations.
They do not install a driver, request microphone permission, or change the Mac's
audio settings. Real device testing is recorded in the
[release checklist](RELEASE_CHECKLIST.md). CI runs on Apple Silicon and Intel.

## Audio path

The virtual device carries eight-channel, 48 kHz PCM. The app reads it through
AUHAL, mixes to stereo, and uses Apple's converter at the physical output rate.
The supported output range is 32–192 kHz. Bounded clock correction compensates
for small differences between the virtual and physical device clocks.

Channel order is `L, R, C, LFE, Ls, Rs, Lsr, Rsr`. The mix is:

```text
Left  = L + Cgain*C + 0.707*Ls + 0.5*Lsr
Right = R + Cgain*C + 0.707*Rs + 0.5*Rsr
Cgain = 0.707 * 10^(boost_dB / 20)
```

Boost defaults to 0 dB and ranges from 0 to 9 dB. LFE is omitted. Invalid samples
are silenced; peaks are clipped before software volume attenuation. Higher boost
can cause audible distortion in loud scenes.

## Release

Complete the hardware checklist on the source revision being released, then run:

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-saved-keychain-profile' \
RELEASE_TESTED_COMMIT='full-tested-commit-sha' \
./release.sh
```

The script requires a clean checkout, rebuilds and tests the app, checks the
signatures, submits to Apple, staples the notarization ticket, and checks
Gatekeeper. It also verifies the final extracted ZIP and writes a SHA-256
checksum. Publishing that ZIP to GitHub is a separate step.

Driver installation is pinned to Developer ID team `MD83L42DNL`. Changing the
signing team also requires updating that verification requirement.

Keep signing keys and notarization credentials out of the repository. Use a saved
Keychain profile for `notarytool`.
