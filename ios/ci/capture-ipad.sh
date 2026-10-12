#!/bin/bash
set -euo pipefail
mkdir -p build/ipad
xcrun simctl list -j > build/ipad/simulators.json
read -r TYPE RUNTIME < <(python3 - <<'PY'
import json
data = json.load(open('build/ipad/simulators.json'))
types = [t for t in data['devicetypes'] if t['name'].startswith('iPad')]
device = next((t for t in types if '11-inch' in t['name'] and 'M4' in t['name']), types[-1])
runtimes = [r for r in data['runtimes'] if r.get('isAvailable') and 'iOS' in r['name']]
runtime = next((r for r in runtimes if r['version'] == '18.5'), runtimes[-1])
print(device['identifier'], runtime['identifier'])
PY
)
DEVICE=$(xcrun simctl create StudentHelper-iPad "$TYPE" "$RUNTIME")
trap 'xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
TEST_TARGETS=(-only-testing:StudentHelperTests -only-testing:StudentHelperUITests/NotebookUITests)
if [[ "${IPAD_TEST_SCOPE:-all}" == "mcp" ]]; then
  TEST_TARGETS=(-only-testing:StudentHelperUITests/NotebookUITests/testMCPImportsProblemDrawsCorrectionAndUserCanStop)
fi
if [[ "${IPAD_TEST_SCOPE:-all}" == "dock" ]]; then
  TEST_TARGETS=(-only-testing:StudentHelperUITests/NotebookUITests/testToolDockSnapsToEveryEdgeAndEraserHasNoMenu)
fi
if [[ "${IPAD_TEST_SCOPE:-all}" == "windows" ]]; then
  TEST_TARGETS=(-only-testing:StudentHelperUITests/NotebookUITests/testNotebookPagePaperAndAssistantThroughUI)
fi
if [[ "${IPAD_TEST_SCOPE:-all}" == "touch" ]]; then
  TEST_TARGETS=(-only-testing:StudentHelperTests/NotebookAgentTests -only-testing:StudentHelperUITests/NotebookUITests/testMCPImportsProblemDrawsCorrectionAndUserCanStop -only-testing:StudentHelperUITests/NotebookUITests/testNotebookPagePaperAndAssistantThroughUI)
fi
if ! xcodebuild -project StudentHelper.xcodeproj -scheme StudentHelper -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath build/simulator \
  -parallel-testing-enabled NO -resultBundlePath build/ipad/notebook-tests.xcresult \
  "${TEST_TARGETS[@]}" \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test | tee ipad-tests.log; then
  xcrun xcresulttool export attachments --path build/ipad/notebook-tests.xcresult --output-path build/ipad/previews || true
  exit 1
fi
xcrun xcresulttool export attachments --path build/ipad/notebook-tests.xcresult --output-path build/ipad/previews
APP=build/simulator/Build/Products/Debug-iphonesimulator/StudentHelper.app
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.studenthelper.yibu --notebook-preview
sleep 3
xcrun simctl io "$DEVICE" screenshot build/ipad/shelf.png
