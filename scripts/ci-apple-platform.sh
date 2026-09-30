#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

platform="${1:?macos, iphone 또는 ipad를 지정하세요}"
case "$platform" in
  macos)
    scheme=MirrorMac
    sdk=macosx
    destination='platform=macOS,arch=arm64'
    ;;
  iphone|ipad)
    scheme=MirrorIOS
    sdk=iphonesimulator
    device_id=$(python3 - "$platform" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

expected = json.loads(Path('development-baseline.json').read_text())['observedToolchain']['iOSSimulatorRuntime']
runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))
runtime = next(value for value in runtimes['runtimes'] if value['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-') and value['version'] == expected and value.get('isAvailable'))
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
family = 'iPhone' if sys.argv[1] == 'iphone' else 'iPad'
device = next(value for value in devices['devices'][runtime['identifier']] if value['name'].startswith(family))
print(device['udid'])
PY
    )
    destination="platform=iOS Simulator,id=$device_id"
    xcrun simctl boot "$device_id"
    xcrun simctl bootstatus "$device_id" -b
    ;;
  *)
    echo '지원하지 않는 플랫폼입니다.' >&2
    exit 2
    ;;
esac

result_dir=".build/ci-$platform"
mkdir -p "$result_dir"
if test -e "$result_dir/Tests.xcresult"; then
  echo '이전 xcresult가 있으므로 새 결과 디렉터리에서 실행해야 합니다.' >&2
  exit 2
fi

if xcodebuild -project Mirror.xcodeproj -scheme "$scheme" -configuration Debug \
  -sdk "$sdk" -destination "$destination" -jobs 2 \
  -derivedDataPath "$result_dir/DerivedData" -resultBundlePath "$result_dir/Tests.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO build test 2>&1 | tee "$result_dir/test.log"; then
  xcrun xcresulttool get test-results summary --path "$result_dir/Tests.xcresult" > "$result_dir/summary.json"
  python3 scripts/ci_results.py xcode "$result_dir/summary.json"
else
  test_status=$?
  python3 scripts/ci_results.py diagnostics "$result_dir/test.log" || true
  exit "$test_status"
fi
