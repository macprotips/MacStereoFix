# Security reports

MacStereoFix installs a user-space CoreAudio plug-in and processes system audio.
A driver defect can interrupt audio beyond this app, so report memory safety,
privileged installation, signing, or unexpected capture problems as security issues.

Use **Security → Report a vulnerability** to
[send a private report](https://github.com/macprotips/MacStereoFix/security/advisories/new).
Private reporting is enabled. Include the app/driver version, macOS version,
steps to reproduce, and whether normal output can be restored. Do not attach
private recordings, passwords, signing keys or notarization credentials.

For ordinary audio compatibility bugs, use GitHub Issues. If sound is stuck,
select your speakers or headphones in System Settings → Sound → Output.

The 1.3.0 audit candidate has automated safety checks but is not yet a public
release. Older published binaries do not receive fixes until a new release is
built, verified and published. No release is a guarantee against all vulnerabilities.
