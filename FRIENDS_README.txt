MacStereoFix — installation and recovery
=======================================

Use a signed and notarized release from:
https://github.com/macprotips/MacStereoFix/releases

1. Unzip and move MacStereoFix.app to Applications.
2. Open it. Click the speaker icon in the menu bar.
3. Finish calls and recordings before clicking Install Driver. macOS asks
   for an administrator password. All Mac audio briefly stops while the
   driver loads. The app reports when it is ready.
4. Select your real speakers or headphones, then turn Force Stereo on.
5. Allow the microphone permission prompt. MacStereoFix reads audio from
   its virtual device, not your physical microphone. It does not save
   recordings or send audio over the network.

Start with a low listening volume. Dialogue boost can make voices clearer,
but high boost can distort loud scenes. Volume and Mute control routed
sound. Turning Force Stereo off returns to your device's normal volume.

The app starts off each time. Sleep, an output disconnect, a routing error,
or a manual change in macOS Sound settings stops routing. Select the output
again and turn it on when you are ready. Some Bluetooth call modes are
mono and cannot be used as stereo outputs.

If sound stops:
Open System Settings > Sound > Output and choose your normal speakers or
headphones. This bypasses MacStereoFix. Do not choose MacStereoFix manually
while the app is off. If a driver update does not load, restart the Mac.

If capture permission was denied:
Open System Settings > Privacy & Security > Microphone and allow
MacStereoFix, then try again.

To remove it:
Use Advanced > Uninstall Driver, then move the app to the Trash. Removal
requires an administrator password and briefly interrupts all Mac audio.

A verified release should pass normal macOS security checks. If macOS says
it cannot verify the app, stop and get a verified release. Do not disable
Gatekeeper or SIP, or use quarantine-removal commands to run it.

MacStereoFix only redirects apps that follow the macOS default output.
Apps using their own output, system alerts, and protected media may differ.
