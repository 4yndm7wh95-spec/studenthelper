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
xcrun simctl addmedia "$DEVICE" Tests/Fixtures/homework.png
# Warm up the freshly created simulator's photo library before opening PHPicker.
xcrun simctl launch "$DEVICE" com.apple.mobileslideshow
sleep 5
xcrun simctl terminate "$DEVICE" com.apple.mobileslideshow >/dev/null 2>&1 || true
xcrun simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
set -o pipefail
xcodebuild -project StudentHelper.xcodeproj -scheme StudentHelper -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/simulator \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing | tee simulator-test-build.log
# Xcode embeds simulated permissions separately from the macOS code signature.
# Let Xcode generate them; the device IPA remains unsigned.
APP=build/simulator/Build/Products/Debug-iphonesimulator/StudentHelper.app
codesign --verify "$APP"
python3 - <<'PY'
from pathlib import Path
import plistlib
for path in Path('build/simulator/Build/Intermediates.noindex').rglob('*Simulated.xcent'):
    values = plistlib.load(path.open('rb'))
    print('Xcode simulator identity:', path.name, values.get('application-identifier', '(none)'))
PY
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.studenthelper.yibu
sleep 4
xcrun simctl io "$DEVICE" screenshot build/iphone16pro.png
xcrun simctl terminate "$DEVICE" com.studenthelper.yibu >/dev/null 2>&1 || true
if ! xcodebuild -project StudentHelper.xcodeproj -scheme StudentHelper -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/simulator \
  -parallel-testing-enabled NO -resultBundlePath build/model-tests.xcresult \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test-without-building | tee model-tests.log; then
  xcrun xcresulttool export attachments --path build/model-tests.xcresult --output-path build/ui-previews || true
  exit 1
fi
DATA_CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.studenthelper.yibu data)
cp "$DATA_CONTAINER/Library/Application Support/ios-vision-request.json" build/ios-vision-request.json
xcrun xcresulttool export attachments --path build/model-tests.xcresult --output-path build/ui-previews
xcrun simctl terminate "$DEVICE" com.studenthelper.yibu >/dev/null 2>&1 || true
xcrun simctl launch "$DEVICE" com.studenthelper.yibu --model-settings-preview
sleep 3
xcrun simctl io "$DEVICE" screenshot build/iphone-model-settings.png
xcrun simctl terminate "$DEVICE" com.studenthelper.yibu >/dev/null 2>&1 || true
xcrun simctl ui "$DEVICE" appearance light
xcrun simctl launch "$DEVICE" com.studenthelper.yibu --design-preview
sleep 4
xcrun simctl io "$DEVICE" screenshot build/iphone-claude-light.png
xcrun simctl ui "$DEVICE" appearance dark
sleep 3
xcrun simctl io "$DEVICE" screenshot build/iphone-claude-dark.png
