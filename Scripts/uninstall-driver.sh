#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ $EUID -eq 0 ]] || { echo 'Administrator authorization is required.' >&2; exit 1; }
for directory in /Library /Library/Audio /Library/Audio/Plug-Ins /Library/Audio/Plug-Ins/HAL; do
    [[ ! -L "$directory" ]] || { echo "Refusing linked directory: $directory" >&2; exit 1; }
    [[ -e "$directory" ]] || exit 0
    [[ -d "$directory" && $(/usr/bin/stat -f %u "$directory") == 0 ]] || exit 1
    acl=$(/bin/ls -lde "$directory")
    [[ "$acl" != *" allow "* ]] || { echo "Unexpected directory access rules: $directory" >&2; exit 1; }
    mode=$(/usr/bin/stat -f %Lp "$directory")
    (( (8#$mode & 0022) == 0 )) || { echo "Unsafe directory permissions: $directory" >&2; exit 1; }
done
destination=/Library/Audio/Plug-Ins/HAL/MacStereoFix.driver
if [[ -e "$destination" || -L "$destination" ]]; then
    # rm does not traverse a symlink passed as its final path component.
    /bin/rm -rf "$destination"
    if /usr/bin/pgrep -x coreaudiod >/dev/null; then
        /usr/bin/killall coreaudiod || { echo 'Driver removed. Restart your Mac to finish.' >&2; exit 1; }
    fi
fi
