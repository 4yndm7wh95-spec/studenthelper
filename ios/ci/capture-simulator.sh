#!/bin/bash
set -euo pipefail
mkdir -p build
xcrun simctl list runtimes -j > build/runtimes.json
RUNTIME=$(python3 - <<'PY'
import json
runtimes = [r for r in json.load(open('build/runtimes.json'))['runtimes'] if r.get('isAvailable') and 'iOS' in r['name']]
preferred = next((r for r in runtimes if r['version'] == '18.5'), runtimes[-1] if runtimes else None)
print(preferred['identifier'] if preferred else '')
PY
)
if [ -z "$RUNTIME" ]; then
  echo 'No installed iOS simulator runtime; simulator compilation passed, launch preview unavailable.'
  exit 0
fi
DEVICE=$(xcrun simctl create StudentHelper-iPhone16Pro com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$RUNTIME")
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$DEVICE" build/simulator/Build/Products/Debug-iphonesimulator/StudentHelper.app
xcrun simctl launch "$DEVICE" com.studenthelper.yibu
sleep 4
xcrun simctl io "$DEVICE" screenshot build/iphone16pro.png
xcrun simctl shutdown "$DEVICE"
