#!/usr/bin/env bash
set -euo pipefail
ci_phase='Apple CI 준비'
trap 'ci_status=$?; printf "::error::%s 단계 실패 (종료 코드 %s).\n" "$ci_phase" "$ci_status" >&2' ERR
cd "$(dirname "$0")/.."

platform="${1:?macos, iphone 또는 ipad를 지정하세요}"
mode="${2:-all}"
build_number="${GITHUB_RUN_NUMBER:-1}"
ui_appearance="${MIRROR_UI_APPEARANCE-system}"
case "$ui_appearance" in
  system|dark) ;;
  *) echo '지원하지 않는 UI 표시 모드입니다: system 또는 dark를 지정하세요.' >&2; exit 2 ;;
esac
case "$mode" in
  unit|ui-build|ui|all) ;;
  *) echo '지원하지 않는 실행 단계입니다: unit, ui-build, ui 또는 all을 지정하세요.' >&2; exit 2 ;;
esac
# 고정 enum의 관측 annotation만 출력한다. 기존 명령의 결과와 gate는 바꾸지 않는다.
ci_unit_phase_notice() {
  case "$platform:$mode" in
    iphone:unit|iphone:all|ipad:unit|ipad:all) ;;
    *) return 0 ;;
  esac
  case "${1-}" in
    prepare|simulator_select|compile|boot|bootstatus|test|summary|bundle|package) ;;
    *) return 0 ;;
  esac
  case "${2-}" in
    started|completed|failed) ;;
    not_required)
      if test "${1-}" != boot; then return 0; fi
      ;;
    *) return 0 ;;
  esac
  printf '::notice::Apple unit phase: {"scope":"unit","platform":"%s","phase":"%s","state":"%s"}\n' \
    "$platform" "$1" "$2" || true
  return 0
}

case "$platform" in
  macos)
    scheme=MirrorMac
    sdk=macosx
    destination='platform=macOS,arch=arm64'
    ;;
  iphone|ipad)
    scheme=MirrorIOS
    sdk=iphonesimulator
    if test "$mode" = unit || test "$mode" = all; then
      ci_phase='Simulator 선택'
      ci_unit_phase_notice simulator_select started
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
      ci_unit_phase_notice simulator_select completed
    fi
    ;;
  *)
    echo '지원하지 않는 플랫폼입니다.' >&2
    exit 2
    ;;
esac

ci_phase='결과 디렉터리 준비'
result_dir=".build/ci-$platform"
ci_unit_phase_notice prepare started
mkdir -p "$result_dir"
bundle_status=0
package_status=0
if test "$mode" = unit || test "$mode" = all; then
  if test -e "$result_dir/Tests.xcresult" || test -e "$result_dir/UI.xcresult"; then
    echo '이전 xcresult가 있으므로 새 결과 디렉터리에서 실행해야 합니다.' >&2
    exit 2
  fi

  ci_unit_phase_notice prepare completed
  test_actions=(build test)
  if test "$platform" = macos; then
    ci_phase='실제 저장 writer 프로세스 helper 빌드'
    swift build --scratch-path .build/process-probe --product MirrorStoreProbe
    swift build --scratch-path .build/process-probe --show-bin-path > .build/process-probe/bin-path.txt
    # PATH의 python3와 XCTest가 직접 실행하는 Apple interpreter는 다를 수 있다.
    # 실제 helper 의존성을 준비한 뒤 기존 5초 잠금 획득 계약을 그대로 검사한다.
    ci_phase='실제 OS 잠금 helper의 Python 의존성 준비'
    /usr/bin/python3 -u -c 'import fcntl, pathlib, signal, sys; assert callable(fcntl.flock) and callable(signal.pause)'
    echo '::notice::실제 /usr/bin/python3 잠금 helper 의존성을 확인했습니다.'
  fi
  if test "$platform" != macos; then
    # 컴파일 오류는 Simulator를 시작하기 전에 확인한다. build-for-testing은 테스트를 실행하지 않는다.
    ci_phase='Simulator 시작 전 앱·확장·테스트 빌드'
    ci_unit_phase_notice compile started
    if xcodebuild -project Mirror.xcodeproj -scheme "$scheme" -configuration Debug \
      -sdk "$sdk" -destination "$destination" -jobs 2 \
      -derivedDataPath "$result_dir/DerivedData" CURRENT_PROJECT_VERSION="$build_number" CODE_SIGNING_ALLOWED=NO build-for-testing \
      2>&1 | tee "$result_dir/test.log"; then
      ci_unit_phase_notice compile completed
      if test "$device_state" != Booted; then
        ci_phase='Simulator 시작'
        ci_unit_phase_notice boot started
        xcrun simctl boot "$device_id"
        ci_unit_phase_notice boot completed
      else
        ci_unit_phase_notice boot not_required
      fi
      ci_phase='Simulator 준비 완료 확인'
      ci_unit_phase_notice bootstatus started
      xcrun simctl bootstatus "$device_id" -b
      ci_unit_phase_notice bootstatus completed
    else
      build_status=$?
      ci_unit_phase_notice compile failed
      python3 scripts/ci_results.py diagnostics "$result_dir/test.log" || true
      exit "$build_status"
    fi
    test_actions=(test-without-building)
  fi
  ci_phase='단위·저장·시스템 테스트'
  ci_unit_phase_notice test started

  if xcodebuild -project Mirror.xcodeproj -scheme "$scheme" -configuration Debug \
    -sdk "$sdk" -destination "$destination" -jobs 2 \
    -derivedDataPath "$result_dir/DerivedData" -resultBundlePath "$result_dir/Tests.xcresult" \
    -parallel-testing-enabled NO CURRENT_PROJECT_VERSION="$build_number" CODE_SIGNING_ALLOWED=NO "${test_actions[@]}" 2>&1 | tee -a "$result_dir/test.log"; then
    ci_unit_phase_notice test completed
    ci_phase='Xcode 테스트 결과 요약'
    ci_unit_phase_notice summary started
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
           'commit': os.environ.get('GITHUB_SHA', ''),
           'build_number': os.environ.get('GITHUB_RUN_NUMBER', '1')}
(Path(directory) / 'unit-context.json').write_text(json.dumps(context, ensure_ascii=False) + '\n')
PY
    if test -n "${GITHUB_OUTPUT:-}"; then
      printf 'unit_ready=true\n' >> "$GITHUB_OUTPUT"
    fi
    ci_unit_phase_notice summary completed
    ci_phase='필수 unit/integration bundle 실행 확인'
    ci_unit_phase_notice bundle started
    python3 scripts/ci_results.py bundles "$result_dir/tests.json" MirrorDomainTests MirrorDataTests MirrorSystemTests || bundle_status=$?
    if test "$bundle_status" -eq 0; then
      ci_unit_phase_notice bundle completed
    else
      ci_unit_phase_notice bundle failed
    fi
  else
    test_status=$?
    ci_unit_phase_notice test failed
    python3 scripts/ci_results.py diagnostics "$result_dir/test.log" || true
    exit "$test_status"
  fi

  ci_phase='앱과 확장 packaging 확인'
  ci_unit_phase_notice package started
  python3 scripts/ci-package.py "$platform" "$result_dir/DerivedData" || package_status=$?
  if test "$package_status" -eq 0; then
    ci_unit_phase_notice package completed
  else
    ci_unit_phase_notice package failed
  fi
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
if context.get('build_number') != os.environ.get('GITHUB_RUN_NUMBER', '1'):
    raise SystemExit('::error::단위 결과의 build가 현재 UI 실행과 다릅니다.')
expected = ('MirrorMac', 'macosx') if platform == 'macos' else ('MirrorIOS', 'iphonesimulator')
if context.get('platform') != platform or (context.get('scheme'), context.get('sdk')) != expected:
    raise SystemExit('::error::단위 결과의 플랫폼·scheme·SDK가 UI 대상과 다릅니다.')
print(context['scheme'], context['sdk'], context['destination'], sep='\t')
PY
)
IFS=$'\t' read -r scheme sdk destination <<< "$context_values"
ui_scheme="${scheme}UI"
if test "$ui_appearance" = dark; then
  ui_scheme="${scheme}UIDark"
fi

if test "$platform" != macos; then
  ci_phase='UI 직전 같은 Simulator runtime·기기 상태 확인'
  simulator_values=$(python3 - "$destination" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

match = re.fullmatch(r'platform=iOS Simulator,id=([0-9A-Fa-f-]{36})', sys.argv[1])
if match is None:
    raise SystemExit('::error::단위 결과의 Simulator 대상 형식이 잘못됐습니다.')
expected = json.loads(Path('development-baseline.json').read_text())['observedToolchain']['iOSSimulatorRuntime']
runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))
runtime = next((item for item in runtimes['runtimes'] if item['version'] == expected
                and item['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
                and item.get('isAvailable')), None)
if runtime is None:
    raise SystemExit('::error::현재 UI 실행의 필수 Simulator runtime이 없습니다.')
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
matches = [item for item in devices['devices'].get(runtime['identifier'], []) if item['udid'] == match[1]]
if len(matches) != 1 or matches[0]['state'] not in ('Booted', 'Shutdown'):
    raise SystemExit('::error::단위 검사와 같은 UI Simulator의 준비 상태를 확인할 수 없습니다.')
print(matches[0]['udid'], matches[0]['state'])
PY
  )
  read -r device_id device_state <<< "$simulator_values"
  if test "$device_state" = Shutdown; then
    xcrun simctl boot "$device_id"
  fi
  ci_phase='UI 직전 Simulator 준비 완료 확인'
  xcrun simctl bootstatus "$device_id" -b
  echo '::notice::단위 검사와 같은 runtime·Simulator의 UI 실행 준비를 확인했습니다.'
fi

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
print('::notice::현재 xcodebuild -help에서 -enableCodeCoverage 지원을 확인했습니다. UI 빌드와 실행에만 NO를 적용합니다.')
PY
else
  help_status=$?
  printf '::error::실제 xcodebuild 도움말 실행이 실패했습니다(종료 코드 %s). UI 옵션을 추정하지 않습니다.\n' "$help_status" >&2
  exit 2
fi

ui_build_receipt() {
  python3 - "$1" "$result_dir" "$platform" "$scheme" "$sdk" "$destination" "$build_number" "$ui_scheme" "${2:-normal}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

def fail(message):
    raise SystemExit('::error::' + message)

def file_record(path):
    resolved = path.resolve(strict=True)
    if not path.is_relative_to(products) or not resolved.is_relative_to(products) or not resolved.is_file():
        fail('UI 빌드 산출물 파일이 현재 Products 범위 밖이거나 사용할 수 없습니다.')
    digest = hashlib.sha256()
    with resolved.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return {'path': path.relative_to(products).as_posix(),
            'resolved_path': resolved.relative_to(products).as_posix(), 'sha256': digest.hexdigest()}

def bundle_record(bundle):
    resolved = bundle.resolve(strict=True)
    if not bundle.is_relative_to(products) or not resolved.is_relative_to(products) or not resolved.is_dir():
        fail('UI 앱 또는 테스트 bundle이 현재 Products 범위 밖이거나 사용할 수 없습니다.')
    infos = [path for path in (bundle / 'Info.plist', bundle / 'Contents/Info.plist') if path.is_file()]
    if len(infos) != 1:
        fail('실제 UI 앱 또는 테스트 bundle의 Info.plist 경로를 확인할 수 없습니다.')
    info_record = file_record(infos[0])
    info = plistlib.loads(infos[0].read_bytes())
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or not executable or Path(executable).name != executable or executable in ('.', '..'):
        fail('실제 UI 앱 또는 테스트 bundle의 실행파일 정보를 확인할 수 없습니다.')
    if str(info.get('CFBundleVersion')) != build:
        fail('실제 UI 앱 또는 테스트 bundle의 build가 현재 실행 build와 다릅니다.')
    executables = [path for path in (bundle / executable, bundle / 'Contents/MacOS' / executable) if path.is_file()]
    if len(executables) != 1:
        fail('실제 UI 앱 또는 테스트 bundle의 실행파일 경로를 확인할 수 없습니다.')
    return {'path': bundle.relative_to(products).as_posix(),
            'resolved_path': resolved.relative_to(products).as_posix(), 'info': info_record,
            'executable': file_record(executables[0]), 'build_number': build}

def current_state():
    if ui_scheme not in (scheme + 'UI', scheme + 'UIDark'):
        fail('UI 빌드 receipt의 선택 scheme이 현재 플랫폼의 UI scheme과 다릅니다.')
    if not products.is_relative_to(directory) or not products.is_dir():
        fail('현재 UI 빌드의 Products 디렉터리를 확인할 수 없습니다.')
    unit_path = directory / 'unit-context.json'
    unit_bytes = unit_path.read_bytes()
    context = json.loads(unit_bytes)
    expected_context = {'platform': platform, 'scheme': scheme, 'sdk': sdk, 'destination': destination,
                        'run_id': os.environ.get('GITHUB_RUN_ID', ''),
                        'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT', ''),
                        'commit': os.environ.get('GITHUB_SHA', ''), 'build_number': build}
    if context != expected_context:
        fail('UI 빌드 receipt의 단위 결과와 현재 실행 context가 다릅니다.')
    checkout = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, stderr=subprocess.DEVNULL,
                                       timeout=receipt_git_timeout).strip()
    if checkout != context['commit']:
        fail('UI 빌드 receipt의 checkout SHA가 현재 실행과 다릅니다.')
    if subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL, timeout=receipt_git_timeout).returncode != 0:
        fail('UI 빌드 receipt 확인 중 현재 checkout의 추적 파일 변경을 발견했습니다.')
    if subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '--',
                                'App', 'Sources', 'Extensions', 'Tests'], timeout=receipt_git_timeout):
        fail('UI 빌드 receipt 확인 중 현재 checkout에 없는 앱·테스트 원본을 발견했습니다.')
    xctestruns = sorted(path for path in products.rglob('*.xctestrun') if path.is_file())
    if not xctestruns:
        fail('현재 UI build-for-testing의 xctestrun 산출물이 없습니다.')
    # SDK 내부 schema와 파일 이름을 추정하지 않고 실제 생성된 파일 전체를 고정한다.
    xctestrun_records = [file_record(path) for path in xctestruns]
    product_configuration = 'Debug' if platform == 'macos' else 'Debug-iphonesimulator'
    app = bundle_record(products / product_configuration / 'Mirror.app')
    ui_bundles = sorted(path for path in products.rglob(scheme + 'UITests.xctest') if path.is_dir())
    if not ui_bundles:
        fail('현재 UI build-for-testing의 필수 테스트 bundle 산출물이 없습니다.')
    # Products 루트와 Runner 안의 복사본이 함께 존재해도 실제 경로·내용을 모두 검증한다.
    return {'format_version': 1, 'context': context, 'ui_scheme': ui_scheme,
            'configuration': 'Debug', 'code_coverage': False, 'code_signing_allowed': False,
            'unit_context_sha256': hashlib.sha256(unit_bytes).hexdigest(),
            'xctestruns': xctestrun_records, 'app': app,
            'ui_bundles': [bundle_record(path) for path in ui_bundles]}

try:
    arguments = sys.argv[1:]
    if len(arguments) == 8:
        arguments.append('normal')
    action, directory, platform, scheme, sdk, destination, build, ui_scheme, verification_bounds = arguments
    if verification_bounds not in ('normal', 'bounded'):
        fail('지원하지 않는 UI 빌드 receipt 검증 한도입니다.')
    receipt_git_timeout = 5 if verification_bounds == 'bounded' else None
    directory = Path(directory).resolve()
    products = (directory / 'DerivedData/Build/Products').resolve()
    receipt_path = directory / 'ui-build-receipt.json'
    if action == 'record':
        if receipt_path.exists() or receipt_path.is_symlink():
            fail('이전 UI 빌드 receipt가 있으므로 현재 실행의 새 결과 디렉터리가 필요합니다.')
        state = current_state()
        # 이미 있는 파일·끊어진 symlink를 덮어쓰지 않고 현재 실행에서만 만든다.
        with receipt_path.open('x', encoding='utf-8') as stream:
            stream.write(json.dumps(state, ensure_ascii=False, sort_keys=True) + '\n')
    elif action == 'verify':
        if receipt_path.is_symlink() or not receipt_path.is_file():
            fail('현재 UI 빌드 receipt가 없거나 직접 생성한 일반 파일이 아닙니다.')
        if json.loads(receipt_path.read_bytes()) != current_state():
            fail('UI 빌드 receipt의 현재 실행·파일 경로 또는 내용 hash가 달라 실행하지 않습니다.')
    else:
        fail('지원하지 않는 UI 빌드 receipt 작업입니다.')
except (OSError, ValueError, TypeError, AttributeError, KeyError, plistlib.InvalidFileException,
        subprocess.SubprocessError):
    fail('UI 빌드 receipt의 산출물 또는 현재 실행 정보를 확인하지 못했습니다.')
PY
}

if test "$mode" = ui-build || test "$mode" = all; then
  ci_phase='현재 실행의 UI 빌드 준비'
  if test -e "$result_dir/ui-build-receipt.json"; then
    echo '이전 UI 빌드 receipt가 있으므로 현재 실행의 새 결과 디렉터리가 필요합니다.' >&2
    exit 2
  fi
  ui_build_started_seconds=$SECONDS
  touch "$result_dir/ui-build-start.marker"
  if xcodebuild -project Mirror.xcodeproj -scheme "$ui_scheme" -configuration Debug \
    -sdk "$sdk" -destination "$destination" -jobs 2 \
    -derivedDataPath "$result_dir/DerivedData" -parallel-testing-enabled NO \
    -enableCodeCoverage NO CURRENT_PROJECT_VERSION="$build_number" CODE_SIGNING_ALLOWED=NO build-for-testing \
    2>&1 | tee "$result_dir/ui-build.log"; then
    ci_phase='현재 실행의 UI 빌드 산출물 receipt 기록'
    ui_build_receipt record
    printf '::notice::UI compile status=verified elapsed_seconds=%s\n' "$((SECONDS - ui_build_started_seconds))"
    if test -n "${GITHUB_OUTPUT:-}"; then
      printf 'ui_build_ready=true\n' >> "$GITHUB_OUTPUT"
    fi
  else
    ui_build_status=$?
    printf '::notice::UI compile status=failed exit_code=%s elapsed_seconds=%s\n' "$ui_build_status" "$((SECONDS - ui_build_started_seconds))"
    python3 scripts/ci_results.py diagnostics "$result_dir/ui-build.log" || true
    exit "$ui_build_status"
  fi
  if test "$mode" = ui-build; then exit 0; fi
fi

ci_phase='현재 실행의 UI 빌드 receipt와 실제 앱 재검증'
ui_build_receipt verify
echo '::notice::UI build receipt status=verified'
ci_phase='UI 시작시각 기록'
touch "$result_dir/ui-start.marker"
ui_execution_started_seconds=$SECONDS
ci_phase='실제 UI 테스트'
printf '%s\n' '::notice::UI execution start status=started' || true
ci_live_sample_pid=''
ci_live_sample_stop() {
  if test -n "$ci_live_sample_pid"; then
    # 이미 종료된 watcher의 PID가 재사용되어도 다른 프로세스에 신호를 보내지 않는다.
    for ci_live_sample_running_pid in $(jobs -pr); do
      if test "$ci_live_sample_running_pid" = "$ci_live_sample_pid"; then
        kill "$ci_live_sample_pid" 2>/dev/null || true
      fi
    done
    wait "$ci_live_sample_pid" 2>/dev/null || true
    ci_live_sample_pid=''
  fi
}
if test "$platform" = macos && test "$ui_appearance" = system && test "${MIRROR_CI_LIVE_SAMPLE-}" = 1; then
  # 원문은 helper의 RUNNER_TEMP private 디렉터리에서만 보존 후 삭제한다.
  python3 scripts/ci-mac-live-sample.py "$result_dir" "$$" 2>/dev/null &
  ci_live_sample_pid=$!
  trap ci_live_sample_stop EXIT
fi
if xcodebuild -project Mirror.xcodeproj -scheme "$ui_scheme" -configuration Debug \
  -sdk "$sdk" -destination "$destination" -jobs 2 \
  -derivedDataPath "$result_dir/DerivedData" -resultBundlePath "$result_dir/UI.xcresult" \
  -parallel-testing-enabled NO -enableCodeCoverage NO CURRENT_PROJECT_VERSION="$build_number" CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee "$result_dir/ui.log"; then
  ui_execution_elapsed_seconds=$((SECONDS - ui_execution_started_seconds))
  ci_live_sample_stop
  printf '%s\n' '::notice::UI diagnostic origin=uiCommandReturn' || true
  printf '::notice::UI execution status=xcode_complete elapsed_seconds=%s\n' "$ui_execution_elapsed_seconds"
  ci_phase='UI 테스트 결과 요약'
  printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"summary","state":"attempted"}' || true
  if xcrun xcresulttool get test-results summary --path "$result_dir/UI.xcresult" > "$result_dir/ui-summary.json"; then
    printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"summary","state":"succeeded"}' || true
  else
    ui_extraction_status=$?
    printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"summary","state":"failed"}' || true
    printf '::notice::UI xcresult command status: {"origin":"uiCommandReturn","kind":"summary","state":"nonzero","exitCode":%s}\n' "$ui_extraction_status" || true
    printf "::error::%s 단계 실패 (종료 코드 %s).\n" "$ci_phase" "$ui_extraction_status" >&2 || true
    exit "$ui_extraction_status"
  fi
  printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"tests","state":"attempted"}' || true
  if xcrun xcresulttool get test-results tests --path "$result_dir/UI.xcresult" > "$result_dir/ui-tests.json"; then
    printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"tests","state":"succeeded"}' || true
  else
    ui_extraction_status=$?
    printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"tests","state":"failed"}' || true
    printf '::notice::UI xcresult command status: {"origin":"uiCommandReturn","kind":"tests","state":"nonzero","exitCode":%s}\n' "$ui_extraction_status" || true
    printf "::error::%s 단계 실패 (종료 코드 %s).\n" "$ci_phase" "$ui_extraction_status" >&2 || true
    exit "$ui_extraction_status"
  fi
  # 동일 원본 캡처의 허용 metadata만 보고하며 테스트·게시 성공 판정에는 사용하지 않는다.
  python3 scripts/ci_results.py native-screenshot-diagnostics "$result_dir/ui.log" || true
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
  ci_phase='실제 UI 빌드와 checkout provenance 확인'
  python3 - "$result_dir" "$platform" "$build_number" <<'PY'
import os
from pathlib import Path
import plistlib
import subprocess
import sys

directory, platform, build = sys.argv[1:]
if subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() != os.environ.get('GITHUB_SHA'):
    raise SystemExit('::error::현재 checkout SHA가 UI 실행 SHA와 다릅니다.')
products = 'Debug' if platform == 'macos' else 'Debug-iphonesimulator'
app = Path(directory) / 'DerivedData/Build/Products' / products / 'Mirror.app'
info = app / ('Contents/Info.plist' if platform == 'macos' else 'Info.plist')
if str(plistlib.loads(info.read_bytes()).get('CFBundleVersion')) != build:
    raise SystemExit('::error::실제 UI 앱의 build가 현재 실행 build와 다릅니다.')
print('::notice::현재 checkout SHA와 실제 UI 앱 build가 일치합니다.')
PY
  ci_phase='실제 SDK xcresult attachment export 지원 확인'
  attachments_help="$result_dir/ui-attachments-help.txt"
  xcrun xcresulttool export attachments --help > "$attachments_help" 2>&1
  python3 - "$attachments_help" <<'PY'
from pathlib import Path
import re
import sys

help_text = Path(sys.argv[1]).read_text(errors='replace')
if any(re.search(r'(?<![A-Za-z-])' + option + r'(?=[\s=]|$)', help_text) is None
       for option in ('--path', '--output-path')):
    raise SystemExit('::error::실제 xcresulttool 도움말에서 attachment export 옵션을 확인하지 못했습니다.')
print('::notice::실제 xcresulttool export attachments --help에서 --path/--output-path를 확인했습니다.')
PY
  ci_phase='성공한 UI 실행의 명명된 앱샷 export'
  xcrun xcresulttool export attachments --path "$result_dir/UI.xcresult" --output-path "$result_dir/ui-attachments"
  evidence_platform="$platform"
  if test "$platform" = macos; then evidence_platform=mac; fi
  ci_phase='앱샷 공개 allowlist와 필수 화면 증거 검증'
  python3 scripts/ci-ui-evidence.py prepare --input "$result_dir/ui-attachments" --output "$result_dir/ui-screenshots" \
    --platform "$evidence_platform" --sha "${GITHUB_SHA:?}" --build-number "$build_number" \
    --run-id "${GITHUB_RUN_ID:?}" --attempt "${GITHUB_RUN_ATTEMPT:?}"
  if test -n "${GITHUB_OUTPUT:-}"; then
    printf 'ui_evidence_ready=true\n' >> "$GITHUB_OUTPUT"
  fi
else
  test_status=$?
  ui_execution_elapsed_seconds=$((SECONDS - ui_execution_started_seconds))
  ci_live_sample_stop
  printf '%s\n' '::notice::UI diagnostic origin=uiCommandReturn' || true
  printf '::notice::UI execution status=failed exit_code=%s elapsed_seconds=%s\n' "$test_status" "$ui_execution_elapsed_seconds"
  python3 scripts/ci_results.py diagnostics "$result_dir/ui.log" || true
  python3 scripts/ci-crash.py "$platform" "$result_dir" || true
  # 실패한 UI 실행도 실제 수와 실패/skip을 남긴다. underlying xcodebuild 실패는 그대로 반환한다.
  printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"summary","state":"attempted"}' || true
  if xcrun xcresulttool get test-results summary --path "$result_dir/UI.xcresult" > "$result_dir/ui-summary.json"; then
    printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"summary","state":"succeeded"}' || true
    python3 scripts/ci_results.py xcode "$result_dir/summary.json" "$result_dir/ui-summary.json" || true
  else
    ui_extraction_status=$?
    printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"summary","state":"failed"}' || true
    printf '::notice::UI xcresult command status: {"origin":"uiCommandReturn","kind":"summary","state":"nonzero","exitCode":%s}\n' "$ui_extraction_status" || true
  fi
  printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"tests","state":"attempted"}' || true
  if xcrun xcresulttool get test-results tests --path "$result_dir/UI.xcresult" > "$result_dir/ui-tests.json"; then
    printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"tests","state":"succeeded"}' || true
    python3 scripts/ci_results.py ui-tree "$result_dir/ui-tests.json" || true
  else
    ui_extraction_status=$?
    printf '%s\n' '::notice::UI xcresult extraction: {"origin":"uiCommandReturn","kind":"tests","state":"failed"}' || true
    printf '::notice::UI xcresult command status: {"origin":"uiCommandReturn","kind":"tests","state":"nonzero","exitCode":%s}\n' "$ui_extraction_status" || true
  fi
  # 현재 실패의 두 명명된 창 캡처만 별도로 보존한다. SDK 전체 export는 임시 폴더에서 삭제한다.
  # 이 보조 경로의 실패는 원래 xcodebuild 종료 코드와 기존 수용 gate를 바꾸지 않는다.
  if test "$platform" = macos && ui_build_receipt verify bounded > /dev/null 2>&1; then
    if python3 scripts/ci-ui-evidence.py private-native-failure --input "$result_dir" \
      --output "$result_dir/ui-private-diagnostics" --native-exit-code "$test_status" \
      --sha "${GITHUB_SHA:?}" --build-number "$build_number" \
      --run-id "${GITHUB_RUN_ID:?}" --attempt "${GITHUB_RUN_ATTEMPT:?}"; then
      if test -n "${GITHUB_OUTPUT:-}"; then
        printf 'ui_private_diagnostics_ready=true\n' >> "$GITHUB_OUTPUT" || true
      fi
    fi
  fi
  exit "$test_status"
fi
