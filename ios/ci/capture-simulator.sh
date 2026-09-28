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
  echo 'An iOS simulator runtime is required for model connection tests.'
  exit 1
fi
DEVICE=$(xcrun simctl create StudentHelper-iPhone16Pro com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$RUNTIME")
trap 'xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$DEVICE" build/simulator/Build/Products/Debug-iphonesimulator/StudentHelper.app
xcrun simctl launch "$DEVICE" com.studenthelper.yibu
sleep 4
xcrun simctl io "$DEVICE" screenshot build/iphone16pro.png
set -o pipefail
xcodebuild -project StudentHelper.xcodeproj -scheme StudentHelper -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/simulator \
  -parallel-testing-enabled NO -resultBundlePath build/model-tests.xcresult \
  CODE_SIGNING_ALLOWED=NO test | tee model-tests.log
xcrun simctl terminate "$DEVICE" com.studenthelper.yibu >/dev/null 2>&1 || true
xcrun simctl launch "$DEVICE" com.studenthelper.yibu --model-settings-preview
sleep 3
xcrun simctl io "$DEVICE" screenshot build/iphone-model-settings.png
