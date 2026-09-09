import os
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parents[1]
base = {k: v for k, v in os.environ.items() if k not in ["SIGN_IDENTITY", "NOTARY_PROFILE", "RELEASE_TESTED_COMMIT"]}
cases = [({}, "SIGN_IDENTITY"), ({"SIGN_IDENTITY": "-"}, "Ad-hoc"),
         ({"SIGN_IDENTITY": "Developer ID Application: Example"}, "NOTARY_PROFILE"),
         ({"SIGN_IDENTITY": "Developer ID Application: Example", "NOTARY_PROFILE": "example"}, "RELEASE_TESTED_COMMIT"),
         ({"SIGN_IDENTITY": "Developer ID Application: Example", "NOTARY_PROFILE": "example",
           "RELEASE_TESTED_COMMIT": "not-the-tested-commit"}, "exact commit")]
for variables, expected in cases:
    result = subprocess.run(["/bin/bash", str(root / "release.sh")], cwd=root,
        env={**base, **variables}, capture_output=True, text=True, timeout=10)
    assert result.returncode != 0 and expected in result.stderr, result

app = plistlib.loads((root / "App/Info.plist").read_bytes())
driver = plistlib.loads((root / "Driver/Info.plist").read_bytes())
for key in ["CFBundleShortVersionString", "CFBundleVersion"]:
    assert app[key] == driver[key]
assert "virtual" in app["NSMicrophoneUsageDescription"]
runtime_version = re.search(r'#define kDriverVersion\s+"([^"]+)"', (root / "Driver/MacStereoFixDriver.c").read_text()).group(1)
assert runtime_version == driver["CFBundleVersion"]
entitlements = plistlib.loads((root / "App/MacStereoFix.entitlements").read_bytes())
assert entitlements == {"com.apple.security.device.audio-input": True}
print("Release gates refuse missing signing, ad-hoc identity, missing notarization and untested source; metadata and entitlements passed")
