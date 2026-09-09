#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo 'Quit MacStereoFix and select a physical output in Sound settings before removing the driver.'
/bin/bash "$ROOT_DIR/Scripts/uninstall-driver.sh"
echo 'Driver removed. You may move MacStereoFix.app to the Trash.'
