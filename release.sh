#!/bin/bash
# Produce a distributable archive only after signing, tests, notarization and Gatekeeper pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity.}"
[[ "$SIGN_IDENTITY" != - ]] || { echo 'Ad-hoc builds cannot be released.' >&2; exit 1; }
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to the saved notarytool Keychain profile name.}"
: "${RELEASE_TESTED_COMMIT:?Complete docs/RELEASE_CHECKLIST.md and set RELEASE_TESTED_COMMIT to the tested commit SHA.}"
cd "$ROOT_DIR"
[[ "$RELEASE_TESTED_COMMIT" == "$(git rev-parse HEAD)" ]] || { echo 'The hardware checklist must cover this exact commit.' >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || { echo 'Commit the complete tested source before releasing.' >&2; exit 1; }

./build.sh
./check.sh
APP="$ROOT_DIR/build/MacStereoFix.app"
VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
TEAM_REQUIREMENT='anchor apple generic and certificate leaf[subject.OU] = "MD83L42DNL" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
/usr/bin/codesign --verify --deep --strict -R "$TEAM_REQUIREMENT" "$APP"
/usr/bin/codesign --verify --strict -R "$TEAM_REQUIREMENT" "$APP/Contents/Resources/MacStereoFix.driver"
/usr/bin/codesign --verify --strict -R "$TEAM_REQUIREMENT" "$APP/Contents/MacOS/MacStereoFixRecovery"

SUBMISSION="$ROOT_DIR/build/notary-submission.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 30m --output-format json > "$ROOT_DIR/build/notary-result.json"
[[ $(/usr/bin/plutil -extract status raw -o - "$ROOT_DIR/build/notary-result.json") == Accepted ]] || {
    echo 'Apple did not accept the build. See build/notary-result.json.' >&2; exit 1;
}
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"

STAGE="$ROOT_DIR/build/release"
mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/MacStereoFix.app"
cp "$ROOT_DIR/INSTALL.txt" "$STAGE/MacStereoFix-INSTRUCTIONS.txt"
cp -R "$ROOT_DIR/ThirdParty" "$STAGE/ThirdParty"
cp "$ROOT_DIR/PRIVACY.md" "$STAGE/PRIVACY.md"
{
    git rev-parse HEAD
    xcrun swiftc --version
    xcrun --show-sdk-version
} > "$STAGE/BUILD-INFO.txt"
ZIP="$ROOT_DIR/build/MacStereoFix-$VERSION.zip"
/usr/bin/ditto -c -k "$STAGE" "$ZIP"
# Validate the artifact users will actually extract, not only the build directory.
VERIFY="$ROOT_DIR/build/release-check"
/usr/bin/ditto -x -k "$ZIP" "$VERIFY"
xcrun stapler validate "$VERIFY/MacStereoFix.app"
/usr/bin/codesign --verify --deep --strict "$VERIFY/MacStereoFix.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$VERIFY/MacStereoFix.app"
(cd "$ROOT_DIR/build" && /usr/bin/shasum -a 256 "MacStereoFix-$VERSION.zip" > "MacStereoFix-$VERSION.zip.sha256")
echo "Verified release archive: $ZIP"
echo 'Publishing to GitHub is a separate step.'
