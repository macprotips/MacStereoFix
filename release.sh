#!/usr/bin/env bash
#
# release.sh — produce a friend-distributable MacStereoFix.zip.
#
# Builds the app + driver, ad-hoc signs them, drops a plain-English
# instructions file next to the app, zips the whole thing.
#
# Output: ./build/MacStereoFix.zip
#
# Friends unzip, follow MacStereoFix-INSTRUCTIONS.txt, and they're done.

set -euo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR="$ROOT_DIR/build"
RELEASE_DIR="$BUILD_DIR/release"
ZIP_OUT="$BUILD_DIR/MacStereoFix.zip"

echo "==> Building app + driver"
"$ROOT_DIR/build.sh"

echo "==> Staging release directory"
rm -rf "$RELEASE_DIR" "$ZIP_OUT"
mkdir -p "$RELEASE_DIR"
cp -R "$BUILD_DIR/MacStereoFix.app" "$RELEASE_DIR/MacStereoFix.app"
cp "$ROOT_DIR/FRIENDS_README.txt" "$RELEASE_DIR/MacStereoFix-INSTRUCTIONS.txt"

# Strip any extended attributes (quarantine, etc.) from the staged copy so
# the zip is as clean as possible. Friends' Macs will re-quarantine on
# download anyway, but starting clean avoids weird leftover xattrs.
xattr -cr "$RELEASE_DIR/MacStereoFix.app" 2>/dev/null || true

echo "==> Zipping into $ZIP_OUT"
( cd "$RELEASE_DIR" && zip -qry "$ZIP_OUT" . )

rm -rf "$RELEASE_DIR"

echo
echo "Release ready:"
echo "  $ZIP_OUT"
ls -lh "$ZIP_OUT"
echo
echo "AirDrop or send this file to a friend. They follow the instructions"
echo "inside MacStereoFix-INSTRUCTIONS.txt."
