# MacStereoFix

A small Mac utility that **forces every app's audio through a stereo downmix**, with a **dialogue boost** so center-channel voices stop getting lost. Built specifically to fix the "voices are super faint in this game" problem in CrossOver bottles, but it works for *any* macOS audio source — games, players, browsers — because it sits at the system audio layer.

It works by installing a small CoreAudio virtual device called **MacStereoFix**, then routing all audio through that device, downmixing 7.1 / 5.1 to 2 channels in real time, and sending the result to the speaker / headphones / AirPods you pick.

This is a personal-use project for a small group of friends. It is not a polished commercial app.

---

## Download

Prebuilt signed + notarized app:
**[MacStereoFix v1.2](https://github.com/macprotips/MacStereoFix/releases/latest)**

Unzip, drag `MacStereoFix.app` into `/Applications`, launch it, and click **Install Driver** in the menu bar popover. That's it.

---

## What's in here

```
MacStereoFix/
├── Driver/                      # Audio server plug-in (C)
│   ├── MacStereoFixDriver.c     # The HAL plug-in implementation
│   └── Info.plist               # Driver bundle metadata
├── App/                         # Menu bar app (Swift)
│   ├── MacStereoFixApp.swift    # @main entry / MenuBarExtra
│   ├── AppState.swift           # Toggle state, persisted prefs, observers
│   ├── MenuBarView.swift        # SwiftUI menu UI
│   ├── AudioRouter.swift        # Two HALOutput AUs + downmix DSP
│   ├── RingBuffer.swift         # SPSC lock-free Float ring buffer
│   ├── SystemAudio.swift        # Device enumeration & default-output control
│   ├── DriverManager.swift      # Install/uninstall via authenticated AppleScript
│   ├── MSFAtomic.h              # C atomic helpers (imported via bridging header)
│   └── Info.plist               # App bundle metadata
├── build.sh                     # Builds driver + app into ./build/
├── install.sh                   # sudo install of the driver
├── uninstall.sh                 # sudo remove of the driver
└── README.md                    # this file
```

---

## How it works (the short version)

1. The **driver** is a CoreAudio audio server plug-in that exposes one virtual device, `MacStereoFix`, with one 8-channel input stream and one 8-channel output stream. Internally it's just a circular buffer: whatever an app writes to the output stream becomes available on the input stream a moment later. The driver does **no DSP**.

2. The **menu bar app** owns two `kAudioUnitSubType_HALOutput` audio units:
   - The **capture unit** is bound to MacStereoFix and pulls 8-channel Float32 audio out of it via an input callback.
   - The **render unit** is bound to your chosen real output device (MacBook speakers, AirPods, monitor, etc.). Its render callback reads 8-channel frames from the ring buffer, **downmixes them to stereo with the current dialogue boost**, and sends them to the device.

3. When you toggle **Force Stereo: ON**, the app:
   - starts both audio units
   - sets the system default output device to MacStereoFix
   so that every app on your Mac (including CrossOver bottles, since Wine respects the macOS default output) sends its audio into our pipeline.

4. When you toggle **OFF**, the app stops the audio units and restores the previous default output device.

The downmix uses the standard ITU coefficients with an adjustable boost on the center channel:

```
Lo = L + Cgain·C + 0.707·Ls + 0.5·Lsr
Ro = R + Cgain·C + 0.707·Rs + 0.5·Rsr
```

`Cgain` defaults to 0.707 (-3 dB) and goes up to roughly 2.0 (+6 dB) at the top of the **Dialogue boost** slider. LFE is dropped.

---

## Building

You need:

- macOS 13+ (the app uses SwiftUI's `MenuBarExtra`)
- Xcode Command Line Tools (`xcode-select --install`) — gives you `clang`, `swiftc`, `codesign`, `lipo`
- A few seconds

```sh
./build.sh
```

This produces:

```
build/MacStereoFix.driver       # the audio server plug-in bundle
build/MacStereoFix.app          # the menu bar app, with the driver bundled inside
```

Both bundles are universal (arm64 + x86_64) and ad-hoc signed.

### Building a signed copy for friends

If you want to distribute to friends without Gatekeeper warnings, set your Developer ID identity before building:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" ./build.sh
```

Then notarize the app (and ideally a `.pkg` you build separately) so friends can install without right-click → Open dance:

```sh
xcrun notarytool submit build/MacStereoFix.app \
    --apple-id you@example.com \
    --team-id TEAMID1234 \
    --password "@keychain:notarytool" \
    --wait
xcrun stapler staple build/MacStereoFix.app
```

(See Apple's notarization docs for the keychain setup.)

---

## Installing

You have two options:

### Option A — let the app install the driver for you (recommended)

1. Drag `build/MacStereoFix.app` into `/Applications`.
2. Launch it. It'll appear in your menu bar as a small speaker icon.
3. Click the icon. Because the driver isn't installed yet, you'll see an **Install Driver** button. Click it.
4. macOS will prompt for your administrator password (this is the standard "do shell script with administrator privileges" dialog). After you authorize it, the app:
   - copies `MacStereoFix.driver` from `Contents/Resources/` into `/Library/Audio/Plug-Ins/HAL/`
   - chowns it to `root:wheel`
   - kicks `coreaudiod` so the device shows up immediately
5. Click the icon again — the toggle and device picker now appear.

### Option B — install from the command line

```sh
./build.sh
sudo ./install.sh
cp -R build/MacStereoFix.app /Applications/
```

Then launch the app from `/Applications`.

---

## Using it

1. Click the menu bar icon.
2. Pick your real output device under **Send stereo to** (your speakers, AirPods, etc.).
3. Flip **Force Stereo** to **ON**.
4. Play your game / movie / whatever. All audio now flows: app → MacStereoFix → MacStereoFix.app → real output, downmixed to stereo.
5. Flip **OFF** when you're done. The app restores your previous default output device.

The first time you toggle ON, macOS will show a **microphone access** prompt. This is because the helper app is technically reading from MacStereoFix's input stream, which macOS classifies as audio input. Allow it. (No actual microphone is involved.)

### CrossOver-specific notes

No need to edit the registry of a bottle in CrossOver or install complicated audio applications. With MacStereoFix ON, anything playing inside a bottle automatically goes through the downmix.

---

## Uninstalling

From the app: **Advanced → Uninstall Driver**. You'll get the same admin prompt.

Or from the command line:

```sh
sudo ./uninstall.sh
rm -rf /Applications/MacStereoFix.app
```

---

## Troubleshooting

**The MacStereoFix device doesn't appear in System Settings → Sound after install.**
1. Check the driver bundle exists: `ls /Library/Audio/Plug-Ins/HAL/MacStereoFix.driver`
2. Check ownership: `ls -ld /Library/Audio/Plug-Ins/HAL/MacStereoFix.driver` should show `root wheel`.
3. Restart coreaudiod manually: `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod`
4. Look at the system log for plug-in load errors:
   `log show --predicate 'subsystem == "com.apple.coreaudio"' --last 5m | grep -i macstereofix`
5. If the driver is **unsigned** or **signed by an unknown identity**, modern macOS may silently refuse to load it. Rebuild with a real `SIGN_IDENTITY` and re-install.

**The toggle turns on but I hear no sound.**
- Check that your **Send stereo to** picker isn't pointing at MacStereoFix itself (it's filtered out, but if your selection is stale it could happen — use **Refresh Devices** in Advanced).
- Open System Settings → Sound and confirm the system output is `MacStereoFix` while the toggle is on.
- If macOS is asking for microphone permission, grant it — without that, the capture side is silent.

**I want to remove everything.**
```sh
sudo ./uninstall.sh
rm -rf /Applications/MacStereoFix.app
defaults delete com.macstereofix.app 2>/dev/null || true
```

---

## Things this v1 deliberately does NOT do

- **No bitstream / passthrough.** PCM only. Dolby Digital and DTS streams are not handled. Almost every game and movie uses PCM through CoreAudio anyway.
- **No per-app routing.** It's a system-wide toggle. If you want one app on stereo and another on surround, you'd need a much fancier app.
- **No multiple sample rates.** The virtual device is locked to 48 kHz. macOS will sample-rate-convert for you when an app outputs 44.1 kHz.
- **No surround panning, EQ, virtualization, or HRTF.** Just an honest downmix.
- **No automatic launch at login.** Add it to System Settings → General → Login Items yourself if you want that.

---

## License

For personal use among friends. Driver structure is modeled on Apple's `NullAudio` sample (Apple Sample Code License). The rest is freshly written.
