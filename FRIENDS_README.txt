MacStereoFix — quick install
============================

What it does
------------
Forces every app's audio on your Mac through a stereo downmix with a
"dialogue boost" so center-channel voices stop getting lost. Built mainly
to fix the "voices are super faint in this game" problem in CrossOver
games, but it works for any audio source.

You'll do a one-time install dance the very first time you open it.
After that it's just "click menu bar icon → flip toggle → play game".


Step 1 — install the app
------------------------
1. Drag MacStereoFix.app into your Applications folder.
2. Double-click MacStereoFix in Applications.
3. macOS will pop up a warning that says something like
   "MacStereoFix can't be opened because Apple cannot check it
    for malicious software." Click OK.
4. Open System Settings (Apple menu → System Settings).
5. Go to Privacy & Security in the sidebar.
6. Scroll down. You'll see a line that says
   "MacStereoFix was blocked from use because it is not from
    an identified developer."
   Click the OPEN ANYWAY button next to it.
7. Confirmation dialog → click Open Anyway → enter your Mac password.
8. The app launches. A small speaker icon appears at the top right
   of your screen, in the menu bar. There is no app window — that's
   on purpose. The app lives entirely in the menu bar.

You only ever do steps 3-7 ONCE. Forever after, MacStereoFix opens like
any normal app.


Step 2 — install the driver (one click)
----------------------------------------
1. Click the small speaker icon in your menu bar.
2. A panel drops down showing "Driver not installed" and a big
   "Install Driver" button. Click it.
3. macOS will ask for your password. Type it and press Enter.
4. Wait about 2 seconds. The panel refreshes and now shows the real UI:
   a Force Stereo toggle, a "Send stereo to" picker, a Volume slider,
   and a Dialogue boost slider.

You only ever do this ONCE. The driver stays installed forever.


Step 3 — use it
---------------
1. Click the menu bar icon any time you want to use it.
2. Under "Send stereo to", pick whatever you actually listen with —
   MacBook speakers, AirPods, headphones, monitor speakers, etc.
3. Flip "Force Stereo" to ON.
4. The very first time you toggle ON, macOS will ask for microphone
   permission. Click Allow.
   (No actual microphone is involved. Our virtual audio device is
   technically classified as an audio input by macOS, so it asks.
   If you click "Don't Allow" by accident, fix it in
   System Settings → Privacy & Security → Microphone → turn on
   MacStereoFix, then quit and relaunch the app.)
5. If voices in your game are still too quiet, drag the
   "Dialogue boost" slider to the right. Start at +3 dB. Go higher
   only if you need to.
6. Launch your game. Audio routes through MacStereoFix automatically.
7. When you're done, click the menu bar icon and flip Force Stereo
   to OFF. Your normal audio comes back exactly as it was.


Important rules
---------------
- NEVER pick "MacStereoFix" manually in System Settings → Sound. The
  app does that for you when you flip the toggle on. If you set it
  manually, you'll get silence.
- Don't quit the app while the toggle is ON. Flip it OFF first, then
  quit. (If you forget, the next launch auto-recovers.)
- The macOS volume keys won't work while Force Stereo is on, because
  the active output is a virtual device. Use the Volume slider in
  the menu instead.


If something goes wrong
-----------------------
- "I can't see the menu bar icon."
  It's at the top-right of your screen, near the clock. It's a small
  speaker icon. If your menu bar is full, hold Cmd and drag other
  icons left to make room.

- "I clicked Install Driver and nothing happened / it failed."
  Quit the app, reopen it, try again. The most common cause is the
  password dialog being dismissed too fast.

- "I have no audio at all."
  Open System Settings → Sound → Output and click your normal output
  device (MacBook Pro Speakers, AirPods, etc). Audio comes back
  immediately.

- "Voices are still faint."
  Push the Dialogue boost slider higher. The default is conservative.

- "I want to remove it."
  Click the menu bar icon → Advanced → Uninstall Driver. Then drag
  MacStereoFix.app from /Applications to the Trash.
