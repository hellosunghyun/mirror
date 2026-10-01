#!/usr/bin/env bash
set -euo pipefail
ci_phase='Apple CI 준비'
trap 'ci_status=$?; printf "::error::%s 단계 실패 (종료 코드 %s).\n" "$ci_phase" "$ci_status" >&2' ERR
cd "$(dirname "$0")/.."

platform="${1:?macos, iphone 또는 ipad를 지정하세요}"
mode="${2:-all}"
case "$mode" in
  unit|ui|all) ;;
  *) echo '지원하지 않는 실행 단계입니다: unit, ui 또는 all을 지정하세요.' >&2; exit 2 ;;
esac
case "$platform" in
  macos)
    scheme=MirrorMac
    sdk=macosx
    destination='platform=macOS,arch=arm64'
    ;;
  iphone|ipad)
    scheme=MirrorIOS
    sdk=iphonesimulator
    if test "$mode" != ui; then
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
    fi
    ;;
  *)
    echo '지원하지 않는 플랫폼입니다.' >&2
    exit 2
    ;;
esac

ci_phase='결과 디렉터리 준비'
result_dir=".build/ci-$platform"
mkdir -p "$result_dir"
bundle_status=0
package_status=0
if test "$mode" != ui; then
  if test -e "$result_dir/Tests.xcresult" || test -e "$result_dir/UI.xcresult"; then
    echo '이전 xcresult가 있으므로 새 결과 디렉터리에서 실행해야 합니다.' >&2
    exit 2
  fi

  test_actions=(build test)
  if test "$platform" = macos; then
    ci_phase='실제 저장 writer 프로세스 helper 빌드'
    swift build --scratch-path .build/process-probe --product MirrorStoreProbe
    swift build --scratch-path .build/process-probe --show-bin-path > .build/process-probe/bin-path.txt
  fi
  if test "$platform" != macos; then
    # 컴파일 오류는 Simulator를 시작하기 전에 확인한다. build-for-testing은 테스트를 실행하지 않는다.
    ci_phase='Simulator 시작 전 앱·확장·테스트 빌드'
    if xcodebuild -project Mirror.xcodeproj -scheme "$scheme" -configuration Debug \
      -sdk "$sdk" -destination "$destination" -jobs 2 \
      -derivedDataPath "$result_dir/DerivedData" CODE_SIGNING_ALLOWED=NO build-for-testing \
      2>&1 | tee "$result_dir/test.log"; then
      if test "$device_state" != Booted; then
        ci_phase='Simulator 시작'
        xcrun simctl boot "$device_id"
      fi
      ci_phase='Simulator 준비 완료 확인'
      xcrun simctl bootstatus "$device_id" -b
    else
      build_status=$?
      python3 scripts/ci_results.py diagnostics "$result_dir/test.log" || true
      exit "$build_status"
    fi
    test_actions=(test-without-building)
  fi
  ci_phase='단위·저장·시스템 테스트'

  if xcodebuild -project Mirror.xcodeproj -scheme "$scheme" -configuration Debug \
    -sdk "$sdk" -destination "$destination" -jobs 2 \
    -derivedDataPath "$result_dir/DerivedData" -resultBundlePath "$result_dir/Tests.xcresult" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "${test_actions[@]}" 2>&1 | tee -a "$result_dir/test.log"; then
    ci_phase='Xcode 테스트 결과 요약'
    xcrun xcresulttool get test-results summary --path "$result_dir/Tests.xcresult" > "$result_dir/summary.json"
    xcrun xcresulttool get test-results tests --path "$result_dir/Tests.xcresult" > "$result_dir/tests.json"
    # 실제 build/test와 두 xcresult 추출이 끝난 뒤에만 독립 UI 단계를 허용한다.
    python3 - "$result_dir" "$platform" "$scheme" "$sdk" "$destination" <<'PY'
import json
import os
import sys
from pathlib import Path

directory, platform, scheme, sdk, destination = sys.argv[1:]
context = {'platform': platform, 'scheme': scheme, 'sdk': sdk, 'destination': destination,
           'run_id': os.environ.get('GITHUB_RUN_ID', ''),
           'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT', ''),
           'commit': os.environ.get('GITHUB_SHA', '')}
(Path(directory) / 'unit-context.json').write_text(json.dumps(context, ensure_ascii=False) + '\n')
PY
    if test -n "${GITHUB_OUTPUT:-}"; then
      printf 'unit_ready=true\n' >> "$GITHUB_OUTPUT"
    fi
    ci_phase='필수 unit/integration bundle 실행 확인'
    python3 scripts/ci_results.py bundles "$result_dir/tests.json" MirrorDomainTests MirrorDataTests MirrorSystemTests || bundle_status=$?
  else
    test_status=$?
    python3 scripts/ci_results.py diagnostics "$result_dir/test.log" || true
    exit "$test_status"
  fi

  ci_phase='앱과 확장 packaging 확인'
  python3 scripts/ci-package.py "$platform" "$result_dir/DerivedData" || package_status=$?
  if test "$mode" = unit; then
    if test "$bundle_status" -ne 0 || test "$package_status" -ne 0; then
      ci_phase='필수 bundle·packaging 결과'
      exit 1
    fi
    exit 0
  fi
fi

ci_phase='현재 실행의 단위 결과와 UI 대상 확인'
if test -e "$result_dir/UI.xcresult"; then
  echo '이전 UI xcresult가 있으므로 현재 실행의 새 결과 디렉터리가 필요합니다.' >&2
  exit 2
fi
context_values=$(python3 - "$result_dir" "$platform" <<'PY'
import json
import os
import sys
from pathlib import Path

directory = Path(sys.argv[1])
platform = sys.argv[2]
for name in ('Tests.xcresult', 'DerivedData'):
    if not (directory / name).is_dir():
        raise SystemExit(f'::error::{name}: 현재 실행의 단위 build/test 결과가 없습니다.')
for name in ('summary.json', 'tests.json', 'unit-context.json'):
    if not (directory / name).is_file() or (directory / name).stat().st_size == 0:
        raise SystemExit(f'::error::{name}: 현재 실행의 단위 결과가 준비되지 않았습니다.')
context = json.loads((directory / 'unit-context.json').read_text())
for key, variable in [('run_id', 'GITHUB_RUN_ID'), ('run_attempt', 'GITHUB_RUN_ATTEMPT'), ('commit', 'GITHUB_SHA')]:
    if context.get(key) != os.environ.get(variable, ''):
        raise SystemExit('::error::다른 실행의 단위 결과를 UI 검사에 재사용할 수 없습니다.')
expected = ('MirrorMac', 'macosx') if platform == 'macos' else ('MirrorIOS', 'iphonesimulator')
if context.get('platform') != platform or (context.get('scheme'), context.get('sdk')) != expected:
    raise SystemExit('::error::단위 결과의 플랫폼·scheme·SDK가 UI 대상과 다릅니다.')
print(context['scheme'], context['sdk'], context['destination'], sep='\t')
PY
)
IFS=$'\t' read -r scheme sdk destination <<< "$context_values"

ci_phase='실제 Xcode UI coverage 옵션 지원 확인'
help_path="$result_dir/ui-xcodebuild-help.txt"
if xcodebuild -help > "$help_path" 2>&1; then
  python3 - "$help_path" <<'PY'
import re
import sys
from pathlib import Path

help_text = Path(sys.argv[1]).read_text(errors='replace')
if re.search(r'^\s*-enableCodeCoverage(?:\s|$)', help_text, re.MULTILINE) is None:
    print('::error::실제 xcodebuild 도움말에서 -enableCodeCoverage 지원을 확인하지 못했습니다.', file=sys.stderr)
    raise SystemExit(2)
print('::notice::현재 xcodebuild -help에서 -enableCodeCoverage 지원을 확인했습니다. UI 실행에만 NO를 적용합니다.')
PY
else
  help_status=$?
  printf '::error::실제 xcodebuild 도움말 실행이 실패했습니다(종료 코드 %s). UI 옵션을 추정하지 않습니다.\n' "$help_status" >&2
  exit 2
fi

ci_phase='UI 시작시각 기록'
touch "$result_dir/ui-start.marker"
ci_phase='실제 UI 테스트'
if xcodebuild -project Mirror.xcodeproj -scheme "${scheme}UI" -configuration Debug \
  -sdk "$sdk" -destination "$destination" -jobs 2 \
  -derivedDataPath "$result_dir/DerivedData" -resultBundlePath "$result_dir/UI.xcresult" \
  -parallel-testing-enabled NO -enableCodeCoverage NO CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$result_dir/ui.log"; then
  ci_phase='UI 테스트 결과 요약'
  xcrun xcresulttool get test-results summary --path "$result_dir/UI.xcresult" > "$result_dir/ui-summary.json"
  xcrun xcresulttool get test-results tests --path "$result_dir/UI.xcresult" > "$result_dir/ui-tests.json"
  python3 scripts/ci_results.py ui-tree "$result_dir/ui-tests.json"
  ci_phase='필수 UI bundle·baseline·현재 선언의 실제 실행 검증'
  python3 scripts/ci_results.py ui-guard "$result_dir/ui-tests.json" "${scheme}UITests" Tests/MirrorUITests
  ci_phase='단위·통합·UI 실제 결과 검증'
  python3 scripts/ci_results.py xcode "$result_dir/summary.json" "$result_dir/ui-summary.json"
  # all 호출은 이전과 같이 독립 검증 실패를 최종 상태에 보존한다.
  # 분리 호출의 unit 단계 실패도 workflow의 실패 상태로 남는다.
  if test "$bundle_status" -ne 0 || test "$package_status" -ne 0; then
    ci_phase='필수 bundle·packaging 결과'
    exit 1
  fi
else
  test_status=$?
  python3 scripts/ci_results.py diagnostics "$result_dir/ui.log" || true
  python3 scripts/ci-crash.py "$platform" "$result_dir" || true
  # 실패한 UI 실행도 실제 수와 실패/skip을 남긴다. underlying xcodebuild 실패는 그대로 반환한다.
  if xcrun xcresulttool get test-results summary --path "$result_dir/UI.xcresult" > "$result_dir/ui-summary.json"; then
    python3 scripts/ci_results.py xcode "$result_dir/summary.json" "$result_dir/ui-summary.json" || true
  fi
  if xcrun xcresulttool get test-results tests --path "$result_dir/UI.xcresult" > "$result_dir/ui-tests.json"; then
    python3 scripts/ci_results.py ui-tree "$result_dir/ui-tests.json" || true
  fi
  exit "$test_status"
fi
