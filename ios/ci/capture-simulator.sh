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
set -o pipefail
xcodebuild -project StudentHelper.xcodeproj -scheme StudentHelper -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/simulator \
  CODE_SIGNING_ALLOWED=NO build-for-testing | tee simulator-test-build.log
# Simulator-only identity: unsigned processes cannot access the iOS Keychain.
# The physical iPhone package remains unsigned and gets its identity at sideload signing.
python3 - <<'PY'
import plistlib
identity = 'SIMTEST123.com.studenthelper.yibu'
with open('build/simulator-keychain.plist', 'wb') as file:
    plistlib.dump({'application-identifier': identity, 'keychain-access-groups': [identity],
                  'com.apple.developer.team-identifier': 'SIMTEST123', 'get-task-allow': True}, file)
PY
APP=build/simulator/Build/Products/Debug-iphonesimulator/StudentHelper.app
codesign --force --sign - --entitlements build/simulator-keychain.plist "$APP"
codesign --verify "$APP"
codesign --display --entitlements - --xml "$APP" > build/simulator-entitlements.plist
python3 - <<'PY'
import plistlib
entitlements = plistlib.load(open('build/simulator-entitlements.plist', 'rb'))
assert entitlements['application-identifier'] == 'SIMTEST123.com.studenthelper.yibu'
assert entitlements['keychain-access-groups'] == ['SIMTEST123.com.studenthelper.yibu']
print('Simulator signing identity and Keychain access verified.')
PY
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.studenthelper.yibu
sleep 4
xcrun simctl io "$DEVICE" screenshot build/iphone16pro.png
xcrun simctl terminate "$DEVICE" com.studenthelper.yibu >/dev/null 2>&1 || true
xcodebuild -project StudentHelper.xcodeproj -scheme StudentHelper -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/simulator \
  -parallel-testing-enabled NO -resultBundlePath build/model-tests.xcresult \
  CODE_SIGNING_ALLOWED=NO test-without-building | tee model-tests.log
xcrun simctl terminate "$DEVICE" com.studenthelper.yibu >/dev/null 2>&1 || true
xcrun simctl launch "$DEVICE" com.studenthelper.yibu --model-settings-preview
sleep 3
xcrun simctl io "$DEVICE" screenshot build/iphone-model-settings.png
