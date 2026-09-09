#!/bin/bash
# Developer-only manual installation; prefer the signed app's Install Driver button.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
requirement='identifier "com.macstereofix.driver" and anchor apple generic and certificate leaf[subject.OU] = "MD83L42DNL" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
if [[ ${1:-} == --allow-adhoc ]]; then
    requirement=--allow-adhoc
elif [[ $# -ne 0 ]]; then
    echo 'Usage: sudo ./install.sh [--allow-adhoc]' >&2
    exit 1
fi
echo 'Installing the driver will briefly interrupt all Mac audio.'
/bin/bash "$ROOT_DIR/Scripts/install-driver.sh" "$ROOT_DIR/build/MacStereoFix.driver" "$requirement"
echo 'Driver installed. Open MacStereoFix to select your output.'
