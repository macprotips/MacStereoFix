#!/usr/bin/env bash
#
# uninstall.sh — remove the MacStereoFix driver from /Library/Audio/Plug-Ins/HAL
# and restart coreaudiod. Does not touch /Applications/MacStereoFix.app.
#
# Usage:  sudo ./uninstall.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "uninstall.sh must be run as root."
    echo "Try:  sudo $0"
    exit 1
fi

DST="/Library/Audio/Plug-Ins/HAL/MacStereoFix.driver"

if [[ -d "$DST" ]]; then
    echo "==> Removing $DST"
    rm -rf "$DST"
else
    echo "Driver not installed at $DST — nothing to remove."
fi

echo "==> Restarting coreaudiod"
# launchctl kickstart is blocked by SIP for coreaudiod on modern macOS.
killall coreaudiod 2>/dev/null || true

echo
echo "Done. You can also drag MacStereoFix.app out of /Applications if you want."
