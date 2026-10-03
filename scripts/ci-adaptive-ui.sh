#!/usr/bin/env bash
# GitHub Actions에서만 실행한다. 기존 단위·UI·46장·릴리스 경로는 호출하지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  printf '%s\n' '::error::adaptiveRemoteOnly' >&2
  exit 2
fi

adaptive_platform="${1:?iphone, ipad 또는 macos를 지정하세요}"
adaptive_appearance="${2:?system 또는 dark를 지정하세요}"
adaptive_mode="${3:?build 또는 test를 지정하세요}"
case "$adaptive_mode" in build|test) ;; *) exit 2 ;; esac
case "$adaptive_platform" in iphone|ipad|macos) ;; *) exit 2 ;; esac
case "$adaptive_appearance" in system|dark) ;; *) exit 2 ;; esac
adaptive_dir=".build/ci-adaptive-ui/$adaptive_platform-$adaptive_appearance"
adaptive_native_status=-1
adaptive_args=(--directory "$adaptive_dir" --platform "$adaptive_platform" --appearance "$adaptive_appearance")
adaptive_finish() {
  local adaptive_exit_status=$?
  if [[ "$adaptive_exit_status" != 0 ]]; then
    python3 scripts/ci-adaptive-ui-results.py failure "${adaptive_args[@]}" \
      --phase "$adaptive_mode" --exit-code "$adaptive_exit_status" --native-exit-code "$adaptive_native_status" || true
    printf '%s\n' '::error::adaptiveCommandFailed' >&2
  fi
  return "$adaptive_exit_status"
}
trap adaptive_finish EXIT

if [[ "$adaptive_mode" == build ]]; then
  python3 scripts/ci-adaptive-ui-results.py prepare "${adaptive_args[@]}"
fi
adaptive_context=$(python3 scripts/ci-adaptive-ui-results.py context "${adaptive_args[@]}")
IFS=$'\t' read -r adaptive_scheme adaptive_sdk adaptive_destination <<< "$adaptive_context"

if [[ "$adaptive_mode" == build ]]; then
  set +e
  xcodebuild -project Mirror.xcodeproj -scheme "$adaptive_scheme" -configuration Debug \
    -sdk "$adaptive_sdk" -destination "$adaptive_destination" -jobs 2 \
    -derivedDataPath "$adaptive_dir/DerivedData" -parallel-testing-enabled NO -enableCodeCoverage NO \
    CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:?}" MIRROR_UI_APPEARANCE="$adaptive_appearance" \
    CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tee "$adaptive_dir/build.log"
  adaptive_pipeline_status=("${PIPESTATUS[@]}")
  set -e
  adaptive_native_status="${adaptive_pipeline_status[0]}"
  [[ "$adaptive_native_status" == 0 ]] || exit "$adaptive_native_status"
  [[ "${adaptive_pipeline_status[1]}" == 0 ]] || exit "${adaptive_pipeline_status[1]}"
  python3 scripts/ci-adaptive-ui-results.py receipt-record "${adaptive_args[@]}"
  printf 'adaptive_build_ready=true\n' >> "${GITHUB_OUTPUT:?}"
  exit 0
fi

python3 scripts/ci-adaptive-ui-results.py receipt-verify "${adaptive_args[@]}"
python3 scripts/ci-adaptive-ui-results.py boot "${adaptive_args[@]}"
[[ ! -e "$adaptive_dir/UI.xcresult" && ! -L "$adaptive_dir/UI.xcresult" ]] || exit 2
set +e
xcodebuild -project Mirror.xcodeproj -scheme "$adaptive_scheme" -configuration Debug \
  -sdk "$adaptive_sdk" -destination "$adaptive_destination" -jobs 2 \
  -derivedDataPath "$adaptive_dir/DerivedData" -resultBundlePath "$adaptive_dir/UI.xcresult" \
  -parallel-testing-enabled NO -enableCodeCoverage NO \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:?}" MIRROR_UI_APPEARANCE="$adaptive_appearance" \
  CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee "$adaptive_dir/test.log"
adaptive_pipeline_status=("${PIPESTATUS[@]}")
set -e
adaptive_native_status="${adaptive_pipeline_status[0]}"
[[ "$adaptive_native_status" == 0 ]] || exit "$adaptive_native_status"
[[ "${adaptive_pipeline_status[1]}" == 0 ]] || exit "${adaptive_pipeline_status[1]}"

xcrun xcresulttool get test-results summary --path "$adaptive_dir/UI.xcresult" > "$adaptive_dir/summary.json"
xcrun xcresulttool get test-results tests --path "$adaptive_dir/UI.xcresult" > "$adaptive_dir/tests.json"
python3 scripts/ci-adaptive-ui-results.py guard "${adaptive_args[@]}"
xcrun xcresulttool export attachments --path "$adaptive_dir/UI.xcresult" --output-path "$adaptive_dir/attachments"
python3 scripts/ci-adaptive-ui-results.py evidence "${adaptive_args[@]}"
printf 'adaptive_evidence_ready=true\n' >> "${GITHUB_OUTPUT:?}"
