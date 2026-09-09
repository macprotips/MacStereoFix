# Changelog

## 1.3.0 — Unreleased

- Fixed driver buffer handling and cases that could replay old audio.
- Added output recovery for crashes and failed routing starts.
- Improved device switching, sample-rate conversion, and sleep handling.
- Added volume and mute controls without changing hardware volume or balance.
- Added driver signature checks and rollback if installation fails.
- Updated the menu layout, setup instructions, error messages, and app icon.
- Dialogue boost is now optional under Advanced and off by default.

## 1.2 — April 14, 2026

- Reduced audio buffering to lower playback latency.
- Limited queued audio to prevent startup delays from persisting during playback.

Reinstall the audio driver after upgrading to 1.2; replacing the app alone does
not update it.

## 1.0 — April 11, 2026

Initial release with surround-to-stereo mixing and a menu bar output selector.
