#!/bin/bash
# Compiled into the app by build.sh. Do not execute a mutable resource script as root.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
[[ $EUID -eq 0 ]] || { echo 'Administrator authorization is required.' >&2; exit 1; }
[[ $# -eq 2 ]] || { echo 'Expected driver path and signing requirement.' >&2; exit 1; }
source_driver=$1
requirement=$2
hal=/Library/Audio/Plug-Ins/HAL
destination=$hal/MacStereoFix.driver

# All ancestors must be real, root-owned directories that other users cannot write.
for directory in /Library /Library/Audio /Library/Audio/Plug-Ins "$hal"; do
    [[ ! -L "$directory" ]] || { echo "Refusing linked directory: $directory" >&2; exit 1; }
    if [[ ! -e "$directory" ]]; then /usr/bin/install -d -o root -g wheel -m 755 "$directory"; fi
    [[ -d "$directory" && $(/usr/bin/stat -f %u "$directory") == 0 ]] || exit 1
    acl=$(/bin/ls -lde "$directory")
    [[ "$acl" != *" allow "* ]] || { echo "Unexpected directory access rules: $directory" >&2; exit 1; }
    mode=$(/usr/bin/stat -f %Lp "$directory")
    (( (8#$mode & 0022) == 0 )) || { echo "Unsafe directory permissions: $directory" >&2; exit 1; }
done
[[ -d "$source_driver" && ! -L "$source_driver" ]] || { echo 'Bundled driver is missing or linked.' >&2; exit 1; }
[[ ! -L "$destination" ]] || { echo 'Installed driver is a symbolic link; refusing to replace it.' >&2; exit 1; }

# Copy into a private, root-owned staging directory before verification. A change
# to the app's user-writable source after this point cannot alter the verified copy.
stage=$(/usr/bin/mktemp -d /Library/Audio/.MacStereoFix.XXXXXX)
backup=0
committed=0
cleanup() {
    if [[ $backup == 1 && $committed == 0 && ! -e "$destination" ]]; then
        /bin/mv "$stage/previous" "$destination" || {
            echo "Could not restore the previous driver. Backup retained at $stage/previous" >&2
            return
        }
    fi
    /bin/rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/ditto --noqtn --noextattr --noacl "$source_driver" "$stage/driver"
unsafe=$(/usr/bin/find -P "$stage/driver" \( -type l -o \( ! -type f -a ! -type d \) -o \( -type f -a -links +1 \) \) -print)
[[ -z "$unsafe" ]] || { echo 'Driver contains links or special files.' >&2; exit 1; }
[[ $(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$stage/driver/Contents/Info.plist") == MacStereoFix ]] || exit 1
[[ $(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$stage/driver/Contents/Info.plist") == com.macstereofix.driver ]] || exit 1
if [[ "$requirement" == --allow-adhoc ]]; then
    /usr/bin/codesign --verify --strict "$stage/driver"
else
    /usr/bin/codesign --verify --strict -R "$requirement" "$stage/driver"
fi
/bin/chmod -RN "$stage/driver"
/usr/sbin/chown -R root:wheel "$stage/driver"
/bin/chmod -R u=rwX,go=rX "$stage/driver"
if [[ -e "$destination" ]]; then
    [[ -d "$destination" ]] || { echo 'Existing driver path is not a directory.' >&2; exit 1; }
    /bin/mv "$destination" "$stage/previous"
    backup=1
fi
/bin/mv "$stage/driver" "$destination"
committed=1
# Failure to restart must be reported, even though the copy succeeded.
if /usr/bin/pgrep -x coreaudiod >/dev/null; then
    /usr/bin/killall coreaudiod || { echo 'Driver installed. Restart your Mac to load it.' >&2; exit 1; }
fi
