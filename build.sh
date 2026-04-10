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

SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # `-` means ad-hoc

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

ARCH_FLAGS=()
for a in "${ARCHS[@]}"; do
    ARCH_FLAGS+=( -arch "$a" )
done

clang \
    -bundle \
    -O2 \
    -Wall \
    -Wno-unused-parameter \
    -fvisibility=hidden \
    "${ARCH_FLAGS[@]}" \
    -mmacosx-version-min="$MIN_MACOS" \
    -framework CoreFoundation \
    -framework CoreAudio \
    -o "$DRIVER_BUNDLE/Contents/MacOS/MacStereoFix" \
    "$DRIVER_SRC_DIR/MacStereoFixDriver.c"

# Sign the driver bundle. Drivers loaded by coreaudiod must be signed.
codesign --force --sign "$SIGN_IDENTITY" \
    --timestamp=none \
    --options runtime \
    "$DRIVER_BUNDLE"

#####################################################################
# 2. Build the SwiftUI app (.app bundle)
#####################################################################

echo "==> Building MacStereoFix.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$APP_SRC_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Bundle the freshly-built driver inside the app's Resources so the in-app
# installer can copy it into /Library/Audio/Plug-Ins/HAL when the user clicks
# "Install Driver".
cp -R "$DRIVER_BUNDLE" "$APP_BUNDLE/Contents/Resources/MacStereoFix.driver"

SWIFT_SOURCES=(
    "$APP_SRC_DIR/MacStereoFixApp.swift"
    "$APP_SRC_DIR/AppState.swift"
    "$APP_SRC_DIR/MenuBarView.swift"
    "$APP_SRC_DIR/AudioRouter.swift"
    "$APP_SRC_DIR/RingBuffer.swift"
    "$APP_SRC_DIR/SystemAudio.swift"
    "$APP_SRC_DIR/DriverManager.swift"
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
        -framework Combine \
        -o "$OUT" \
        "${SWIFT_SOURCES[@]}"
    PARTIAL_BINARIES+=( "$OUT" )
done

lipo -create "${PARTIAL_BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/MacStereoFix"
rm -f "${PARTIAL_BINARIES[@]}"

# App needs hardened runtime + same identity for distribution.
# The entitlements file grants microphone access, which is required under
# hardened runtime to read from the MacStereoFix virtual device's input stream.
# Without com.apple.security.device.audio-input, TCC silently denies the prompt
# and AudioUnitRender returns silence.
codesign --force --sign "$SIGN_IDENTITY" \
    --timestamp=none \
    --options runtime \
    --entitlements "$APP_SRC_DIR/MacStereoFix.entitlements" \
    --deep \
    "$APP_BUNDLE"

echo
echo "==> Build complete:"
echo "    $DRIVER_BUNDLE"
echo "    $APP_BUNDLE"
echo
echo "Next:"
echo "  sudo ./install.sh        # install the driver system-wide"
echo "  cp -R build/MacStereoFix.app /Applications/"
