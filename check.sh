#!/bin/bash
# All checks run without sudo, hardware capture, or changes to Mac audio settings.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
[[ -f build/InstallerScripts.swift && -d build/MacStereoFix.app ]] || {
    echo 'Run ./build.sh before ./check.sh.' >&2; exit 1;
}
CHECK_DIR="$ROOT_DIR/.checks"
mkdir -p "$CHECK_DIR"
for script in build.sh release.sh install.sh uninstall.sh check.sh Scripts/*.sh; do /bin/bash -n "$script"; done
for plist in App/Info.plist App/MacStereoFix.entitlements App/PrivacyInfo.xcprivacy Driver/Info.plist; do
    /usr/bin/plutil -lint "$plist"
done
xcrun clang --analyze -Xanalyzer -analyzer-output=text -Wno-unused-parameter Driver/MacStereoFixDriver.c
xcrun clang -g -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -framework CoreAudio -framework CoreFoundation Tests/driver_tests.c -o "$CHECK_DIR/driver-tests"
"$CHECK_DIR/driver-tests"
xcrun swiftc -g -sanitize=address -D MSF_TESTING -import-objc-header App/MSFAtomic.h \
    -framework CoreAudio -framework AudioToolbox App/RingBuffer.swift App/StereoMix.swift \
    App/AudioRouter.swift App/SystemAudio.swift Tests/audio_tests.swift -o "$CHECK_DIR/audio-tests"
"$CHECK_DIR/audio-tests"
xcrun swiftc -g -framework AppKit -framework AVFoundation -framework CoreAudio \
    App/AppState.swift Tests/state_tests.swift -o "$CHECK_DIR/state-tests"
"$CHECK_DIR/state-tests"
xcrun swiftc -g App/DriverManager.swift build/InstallerScripts.swift Tests/installer_quote_tests.swift \
    -o "$CHECK_DIR/quote-tests"
"$CHECK_DIR/quote-tests"
python3 Tests/installer_tests.py
HELPER_DIR="$CHECK_DIR/RecoveryTests.app/Contents/MacOS"
mkdir -p "$HELPER_DIR"
xcrun swiftc Recovery/main.swift Tests/recovery_system_audio.swift -o "$HELPER_DIR/MacStereoFixRecovery"
xcrun swiftc App/AudioRecovery.swift Tests/recovery_harness.swift -o "$HELPER_DIR/RecoveryTests"
python3 Tests/recovery_tests.py "$HELPER_DIR/RecoveryTests"
# ThreadSanitizer is separate from AddressSanitizer and instruments the C atomics.
xcrun clang -g -O1 -fsanitize=thread -framework CoreAudio -framework CoreFoundation \
    Tests/driver_tests.c -o "$CHECK_DIR/driver-tsan"
"$CHECK_DIR/driver-tsan"
xcrun swiftc -g -sanitize=thread -D MSF_TESTING -import-objc-header App/MSFAtomic.h \
    -framework CoreAudio -framework AudioToolbox App/RingBuffer.swift App/StereoMix.swift \
    App/AudioRouter.swift App/SystemAudio.swift Tests/audio_tests.swift -o "$CHECK_DIR/audio-tsan"
"$CHECK_DIR/audio-tsan"
python3 Tests/release_tests.py
/usr/bin/codesign --verify --deep --strict build/MacStereoFix.app
for binary in build/MacStereoFix.app/Contents/MacOS/MacStereoFix \
    build/MacStereoFix.app/Contents/MacOS/MacStereoFixRecovery \
    build/MacStereoFix.driver/Contents/MacOS/MacStereoFix; do
    architectures=$(/usr/bin/lipo -archs "$binary")
    [[ "$architectures" == 'x86_64 arm64' || "$architectures" == 'arm64 x86_64' ]] || {
        echo "Missing universal architectures in $binary" >&2; exit 1;
    }
done
echo 'All automated checks passed. Physical-device release checks are in docs/RELEASE_CHECKLIST.md.'
