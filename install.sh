#!/usr/bin/env bash
#
# install.sh — copy MacStereoFix.driver into the system HAL plug-in directory
# and restart coreaudiod so the device shows up immediately.
#
# This is the manual install path. The app's "Install Driver" button does the
# same thing through an authenticated AppleScript prompt.
#
# Usage:
#   ./build.sh
#   sudo ./install.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must be run as root."
    echo "Try:  sudo $0"
    exit 1
fi

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="$ROOT_DIR/build/MacStereoFix.driver"
DST_DIR="/Library/Audio/Plug-Ins/HAL"
DST="$DST_DIR/MacStereoFix.driver"

if [[ ! -d "$SRC" ]]; then
    echo "Driver bundle not found at $SRC"
    echo "Run ./build.sh first."
    exit 1
fi

echo "==> Installing MacStereoFix driver to $DST"
mkdir -p "$DST_DIR"
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"

echo "==> Restarting coreaudiod"
# launchctl kickstart is blocked by SIP for coreaudiod on modern macOS.
# killall is the supported way: launchd respawns coreaudiod automatically.
killall coreaudiod 2>/dev/null || true

echo
echo "Done. Open System Settings > Sound > Output and you should see"
echo "'MacStereoFix' in the device list. Then launch MacStereoFix.app."
