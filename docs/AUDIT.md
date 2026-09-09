# MacStereoFix safety and release audit

Audit date: September 9, 2026. Baseline: `45624be` on `main` (v1.2 source).
Candidate: 1.3.0, build 4, on `codex/ship-readiness-audit`.

**Decision: do not approve v1.2 for new distribution. The corrected candidate is
not yet approved for public release.** Its local automated checks pass, but actual
installation/audio-device validation and notarization of the new binary remain.
The published v1.2 ZIP has not been replaced.

## Findings and repairs

| Priority | Finding in the original source | Repair |
|---|---|---|
| High | Many driver property getters wrote scalars/strings without checking the caller's buffer length. A one-byte buffer reproduced a heap overflow under AddressSanitizer. | Central size validation, safe partial lists, initialized output lengths, strict format/CF-type/finite-value validation. |
| High | The driver reused circular-buffer slots without tracking the sample time, so missing writes could replay old audio. Shared float storage also lacked synchronization. | Absolute frame timestamps, lock-free atomic samples and sequence checks; stale, incomplete and inactive input returns silence. |
| High | Installation could mask failures with shell chaining, delete the existing driver before a successful copy, and copy a mutable bundle without verifying its identity. | Protected root-owned staging, post-copy signature/team verification, refusal of links/special files/unsafe parent permissions or ACLs, controlled permissions, replacement rollback, and real error propagation. The command is compiled into the signed app. |
| High | Failed output switching could destroy rendering while the UI stayed on and the default still pointed to the virtual device. | Stop and restore before switching; establish the new route only after both callbacks run; cancel if the intended device/default changes while starting. |
| High | Permission denial or delayed authorization could leave the app trying to route silent capture. | Explicit microphone authorization before routing; cancellation and device changes invalidate a pending start. |
| High | A crash could leave normal output stuck until the next launch. Restoration used transient device IDs and ignored failures. | Same-user recovery child triggered by pipe closure, including SIGKILL; persistent device UIDs; physical fallback; errors include manual Sound-settings recovery. No persistent daemon/login item. |
| High | The render code incorrectly assumed AUHAL would convert a 48 kHz client stream to every physical device rate. Independent device clocks could also exhaust/fill the buffer. | Apple's varispeed converter at the real output rate, supported planar formats, a small startup reserve and bounded clock correction. Hardware formats and buffer sizes are not changed. |
| High | The volume bridge wrote to physical devices, could use a stale baseline and did not implement a mute control. | Software attenuation/mute, virtual volume and mute controls, and no hardware volume/balance writes. The UI explains that Off restores normal device loudness. |
| Medium | Partial audio-unit initialization leaked buffers; destruction did not reliably stop all units. | Central cleanup on every start failure; stop/dispose units before releasing callback storage. |
| Medium | Driver IO configuration changed directly in a property setter without the host configuration-change protocol. Timestamp catch-up advanced only one period per call. | Fixed virtual configuration; elapsed-time timestamps and a new seed after restart. Negative preroll safely returns silence. |
| Medium | Disk installation status could say the new driver was ready while CoreAudio still had the old binary loaded. | Read and compare the loaded driver's build number as well as the bundled and installed versions. |
| Medium | Startup enumeration could overwrite a saved output preference; no-device handling retained a stale selection. | Read preferences first, clear vanished selections, stop on disconnection, and permit removal even with no physical output. |
| Medium | Release packaging defaulted to ad-hoc signing, removed extended attributes and called the ZIP ready without notarization. Recursive signing could also apply the app's entitlements to nested code. | Sign inside out, verify each component, gate packaging on tests/clean tested commit/Developer ID/Apple acceptance/stapling/Gatekeeper, then verify the extracted final ZIP and write a checksum. |
| Medium | The user instructions recommended bypassing macOS security and described controls/behavior the UI did not have. | Updated instructions and privacy statement, optional bounded dialogue boost under Advanced (off by default), labeled controls, visible install interruption notices and bounded error display. |
| Maintenance | There was no test suite/CI or included Apple sample notice. | Repeatable native tests, Apple Silicon/Intel CI with a pinned checkout action and read-only token, and Apple's current NullAudio notice included in the source and bundles. |

The heap-overflow reproduction calls the driver directly in an isolated test
process. It establishes a memory-safety defect; this audit did not demonstrate
remote exploitation or bypass of CoreAudio's client/host boundary.

Apple documents AUHAL's sample-rate requirements in
[TN2091](https://developer.apple.com/library/archive/technotes/tn2091/_index.html).
The SDK's `AudioServerPlugIn.h` specifies host-coordinated IO configuration changes
and nonblocking real-time operations. The implementation was checked against the
installed SDK and Apple's [driver sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in).

## Verification completed locally

- Universal arm64/x86_64 app, driver and recovery executable build successfully
  with the project's Developer ID Application identity and hardened runtime.
- Strict recursive signature verification passes. Only the app has the
  `com.apple.security.device.audio-input` entitlement.
- **3,479 property-size cases** pass, plus format, finite-volume, CF-type, mute,
  inactive-input, timestamp, preroll, frame-limit, wrap and stale-audio checks.
- **200,000 concurrent driver writes** pass under AddressSanitizer,
  UndefinedBehaviorSanitizer and ThreadSanitizer.
- **200,000 concurrent application ring-buffer frames** pass; overflow, underflow,
  wrap, reset, skip and negative lengths are covered.
- Production downmix/channel mapping and Apple's converter run **offline at
  32, 44.1, 48, 96 and 192 kHz**. The drift-control model stays bounded for 30
  simulated minutes at clock errors up to ±500 ppm. This is not a hardware soak test.
- **15 routing scenarios** exercise saved preferences, startup recovery,
  permission denial, helper/audio/default failures, volume/mute, Off, switching,
  disconnects, manual defaults, cancellation, reinstall, startup device loss and
  removal without an output. CoreAudio/installer effects are replaced with doubles.
- **11 installer scenarios** pass using the actual copy/signature/permission/
  rollback logic in temporary directories. Root identity, system paths and
  process control are substituted. No real HAL installation is performed.
- Shell and AppleScript quoting pass for quotes, spaces, command metacharacters,
  newlines and Unicode, without administrator access.
- The production recovery-owner code and child are tested for disarm, normal
  owner closure and SIGKILL, with a fake output setter.
- Release-gate rejection tests, metadata/version/entitlement checks, shell/plist
  validation and Clang static analysis pass.
- Redesigned menu views were rendered offscreen in light and dark appearances
  for setup, Off, On, muted, no output, permission denial, busy and long device-name
  states, with test doubles for audio operations. The view uses native labeled
  controls, explicit status text, readable accent colors, a bounded scroll area,
  recovery links, and Command-R / Command-Q shortcuts. Original speaker artwork
  supplies all Finder icon sizes; it uses AppKit drawing without external assets.
  Interactive keyboard and
  VoiceOver testing is still required.
- Read-only live enumeration found this Mac's built-in stereo output at 48 kHz;
  its current output UID was readable. No MacStereoFix driver was loaded.
- A search across the repository's existing history found no matches for the
  tested common private-key, GitHub-token, AWS-key and OpenAI-key patterns.
  No third-party runtime package dependencies were found.

Run `./build.sh && ./check.sh` to reproduce the automated checks. They do not
install a driver, request capture permission, change sound settings, or restart
CoreAudio. The local CLT 27 toolchain emits an Intel compatibility-packs linker
warning while still building both slices; native Intel CI and OS-specific testing
are separate checks.

## Existing download and GitHub settings

The published v1.2 ZIP was inspected without launching it. Its app is universal,
signed by the project's Developer ID team `MD83L42DNL`, and its stapled
notarization ticket validates. Thus the distribution-script gap is about
reproducibility, not a claim that the existing download is unsigned. The ZIP's
published SHA-256 is `42d436c9df06e2af30a8477f33bb5de072e3c6a3ca120db004e0ffcfd02285c5`.

Private vulnerability reporting was disabled and has been enabled. GitHub secret
scanning and push protection were already enabled. CI results and any subsequent
branch-protection changes are recorded in the handoff report. No main-branch
merge, public release, or driver installation was performed during the audit.

## What still prevents release approval

1. **Actual macOS installation and audio tests.** Test fresh install, v1.2 upgrade,
   permission denial/grant, normal output, volume/mute, Force Quit, sleep/wake,
   unplugging, switching, reinstall/removal, and at least an hour of real playback.
   Only built-in speakers are currently available here; USB/Bluetooth and the
   minimum advertised macOS versions need real coverage. Follow
   [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). This step briefly interrupts all
   Mac audio and requires the local administrator/permission prompts.
2. **Notarization of the corrected binary.** The signing certificate is available.
   A usable saved notarization profile has not been identified. The old v1.2
   ticket does not cover the new build. Apple acceptance, stapling and Gatekeeper
   checks must pass for the exact new artifact.
3. **Maintainer sign-off and publication.** Merge only the verified change; publish
   a release with matching source/checksum after the physical checklist and final
   artifact checks. Existing v1.2 users do not receive these changes automatically.

The project still targets macOS 13; a successful cross-compile does not establish
that minimum-version support. Licensing remains the existing personal-use policy;
this audit did not silently relicense the independently written application.
Apple's notarization is an automated security/signing check and is not a guarantee
that software has no bugs. [Apple's explanation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
