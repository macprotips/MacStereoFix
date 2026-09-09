#!/usr/bin/env bash
#
# build.sh — builds MacStereoFix.driver and MacStereoFix.app from source.
#
# Output goes into ./build/. After running this you can:
#   sudo ./install.sh         # copy driver into /Library/Audio/Plug-Ins/HAL
# and then drag build/MacStereoFix.app into /Applications.
#
# To produce a signed build for distribution to friends, set:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# in your environment before running. Without that, the build is ad-hoc signed
# (works on your own Mac but friends will see Gatekeeper warnings).

set -euo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR="$ROOT_DIR/build"
DRIVER_SRC_DIR="$ROOT_DIR/Driver"
APP_SRC_DIR="$ROOT_DIR/App"

DRIVER_BUNDLE="$BUILD_DIR/MacStereoFix.driver"
APP_BUNDLE="$BUILD_DIR/MacStereoFix.app"

MIN_MACOS="13.0"
ARCHS=( "arm64" "x86_64" )

SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # `-` means local development only
SIGN_FLAGS=( --force --sign "$SIGN_IDENTITY" --options runtime )
if [[ "$SIGN_IDENTITY" == - ]]; then
    SIGN_FLAGS+=( --timestamp=none )
else
    SIGN_FLAGS+=( --timestamp )
fi

echo "==> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

#####################################################################
# 1. Build the audio server plug-in (.driver bundle)
#####################################################################

echo "==> Building MacStereoFix.driver"

mkdir -p "$DRIVER_BUNDLE/Contents/MacOS"
mkdir -p "$DRIVER_BUNDLE/Contents/Resources"

cp "$DRIVER_SRC_DIR/Info.plist" "$DRIVER_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/ThirdParty/Apple-NullAudio-LICENSE.txt" "$DRIVER_BUNDLE/Contents/Resources/"

ARCH_FLAGS=()
for a in "${ARCHS[@]}"; do
    ARCH_FLAGS+=( -arch "$a" )
done

clang \
    -bundle \
    -O2 \
    -Wall -Wextra -Werror \
    -Wno-unused-parameter \
    -fvisibility=hidden \
    "${ARCH_FLAGS[@]}" \
    -mmacosx-version-min="$MIN_MACOS" \
    -framework CoreFoundation \
    -framework CoreAudio \
    -o "$DRIVER_BUNDLE/Contents/MacOS/MacStereoFix" \
    "$DRIVER_SRC_DIR/MacStereoFixDriver.c"

# Sign the driver bundle. Drivers loaded by coreaudiod must be signed.
codesign "${SIGN_FLAGS[@]}" "$DRIVER_BUNDLE"

#####################################################################
# 2. Build the SwiftUI app (.app bundle)
#####################################################################

echo "==> Building MacStereoFix.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$APP_SRC_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_SRC_DIR/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/"
cp -R "$ROOT_DIR/ThirdParty" "$APP_BUNDLE/Contents/Resources/"

# Bundle the freshly-built driver inside the app's Resources so the in-app
# installer can copy it into /Library/Audio/Plug-Ins/HAL when the user clicks
# "Install Driver".
cp -R "$DRIVER_BUNDLE" "$APP_BUNDLE/Contents/Resources/MacStereoFix.driver"

# Embed the installer in the signed executable, never run a writable script
# from Resources with administrator privileges.
INSTALL_SCRIPT=$(/usr/bin/base64 < "$ROOT_DIR/Scripts/install-driver.sh" | /usr/bin/tr -d '\n')
UNINSTALL_SCRIPT=$(/usr/bin/base64 < "$ROOT_DIR/Scripts/uninstall-driver.sh" | /usr/bin/tr -d '\n')
cat > "$BUILD_DIR/InstallerScripts.swift" <<EOF
import Foundation
enum InstallerScripts {
    static let install = String(data: Data(base64Encoded: "$INSTALL_SCRIPT")!, encoding: .utf8)!
    static let uninstall = String(data: Data(base64Encoded: "$UNINSTALL_SCRIPT")!, encoding: .utf8)!
}
EOF

SWIFT_SOURCES=(
    "$APP_SRC_DIR/MacStereoFixApp.swift"
    "$APP_SRC_DIR/AppState.swift"
    "$APP_SRC_DIR/MenuBarView.swift"
    "$APP_SRC_DIR/AudioRouter.swift"
    "$APP_SRC_DIR/RingBuffer.swift"
    "$APP_SRC_DIR/SystemAudio.swift"
    "$APP_SRC_DIR/DriverManager.swift"
    "$APP_SRC_DIR/AudioObservation.swift"
    "$APP_SRC_DIR/AudioRecovery.swift"
    "$APP_SRC_DIR/StereoMix.swift"
    "$BUILD_DIR/InstallerScripts.swift"
)

# Build a universal binary by compiling each arch separately and lipo-ing.
PARTIAL_BINARIES=()
for a in "${ARCHS[@]}"; do
    OUT="$BUILD_DIR/MacStereoFix.$a"
    swiftc \
        -O \
        -target "${a}-apple-macos${MIN_MACOS}" \
        -import-objc-header "$APP_SRC_DIR/MSFAtomic.h" \
        -framework SwiftUI \
        -framework AppKit \
        -framework Foundation \
        -framework CoreAudio \
        -framework AudioToolbox \
        -framework AVFoundation \
        -framework Combine \
        -o "$OUT" \
        "${SWIFT_SOURCES[@]}"
    PARTIAL_BINARIES+=( "$OUT" )
done

lipo -create "${PARTIAL_BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/MacStereoFix"
rm -f "${PARTIAL_BINARIES[@]}"

# The recovery helper runs as this user; it has no administrator or audio-input entitlement.
HELPER_BINARIES=()
for a in "${ARCHS[@]}"; do
    OUT="$BUILD_DIR/MacStereoFixRecovery.$a"
    swiftc -O -target "${a}-apple-macos${MIN_MACOS}" \
        -framework CoreAudio -framework Foundation \
        "$ROOT_DIR/Recovery/main.swift" "$APP_SRC_DIR/SystemAudio.swift" -o "$OUT"
    HELPER_BINARIES+=( "$OUT" )
done
lipo -create "${HELPER_BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/MacStereoFixRecovery"
rm -f "${HELPER_BINARIES[@]}"
codesign "${SIGN_FLAGS[@]}" --identifier com.macstereofix.recovery \
    "$APP_BUNDLE/Contents/MacOS/MacStereoFixRecovery"

# Sign inside out. --deep is appropriate for verification, not for signing.
codesign "${SIGN_FLAGS[@]}" --entitlements "$APP_SRC_DIR/MacStereoFix.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo
echo "==> Build complete:"
echo "    $DRIVER_BUNDLE"
echo "    $APP_BUNDLE"
echo
echo "Next: ./check.sh"
if [[ "$SIGN_IDENTITY" == - ]]; then
    echo "Local development only. Explicit local install: sudo ./install.sh --allow-adhoc"
else
    echo "Signed test build. Hardware validation and Apple notarization are still required before distribution."
fi
