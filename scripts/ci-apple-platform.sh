#!/usr/bin/env bash
set -euo pipefail
ci_phase='Apple CI 준비'
trap 'ci_status=$?; printf "::error::%s 단계 실패 (종료 코드 %s).\n" "$ci_phase" "$ci_status" >&2' ERR
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
    ci_phase='Simulator 선택'
    device_info=$(python3 - "$platform" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

expected = json.loads(Path('development-baseline.json').read_text())['observedToolchain']['iOSSimulatorRuntime']
runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))
runtime = next((value for value in runtimes['runtimes'] if value['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-') and value['version'] == expected and value.get('isAvailable')), None)
if runtime is None:
    print(f'::error::iOS {expected}의 사용 가능한 Simulator runtime이 없습니다.', file=sys.stderr)
    raise SystemExit(1)
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
family = 'iPhone' if sys.argv[1] == 'iphone' else 'iPad'
device = next((value for value in devices['devices'].get(runtime['identifier'], []) if value['name'].startswith(family)), None)
if device is None:
    print(f'::error::iOS {expected}의 사용 가능한 {family} Simulator가 없습니다.', file=sys.stderr)
    raise SystemExit(1)
print(device['udid'], device['state'])
PY
    )
    read -r device_id device_state <<< "$device_info"
    destination="platform=iOS Simulator,id=$device_id"
    if test "$device_state" != Booted; then
      ci_phase='Simulator 시작'
      xcrun simctl boot "$device_id"
    fi
    ci_phase='Simulator 준비 완료 확인'
    xcrun simctl bootstatus "$device_id" -b
    ;;
  *)
    echo '지원하지 않는 플랫폼입니다.' >&2
    exit 2
    ;;
esac

ci_phase='결과 디렉터리 준비'
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
  ci_phase='Xcode 테스트 결과 요약'
  xcrun xcresulttool get test-results summary --path "$result_dir/Tests.xcresult" > "$result_dir/summary.json"
  ci_phase='Xcode 테스트 결과 검증'
  python3 scripts/ci_results.py xcode "$result_dir/summary.json"
else
  test_status=$?
  python3 scripts/ci_results.py diagnostics "$result_dir/test.log" || true
  exit "$test_status"
fi
