#!/usr/bin/env bash
# 전용 batch scheme만 사용한다. 기존 native6·46 PNG·서명·Release 게이트는 호출하거나 바꾸지 않는다.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true ]] || { printf '%s\n' '::error::batchRemoteOnly' >&2; exit 2; }
batch_platform="${1:?iphone, ipad 또는 macos를 지정하세요}"
batch_mode="${2:?build 또는 test를 지정하세요}"
case "$batch_platform" in iphone|ipad|macos) ;; *) exit 2 ;; esac
case "$batch_mode" in build|test) ;; *) exit 2 ;; esac
batch_dir=".build/ci-batch-ui/$batch_platform"
batch_native_status=-1
batch_args=(--platform "$batch_platform")
batch_finish() {
  local batch_exit_status=$?
  if [[ "$batch_exit_status" != 0 ]]; then
    if [[ "$batch_native_status" -gt 0 ]]; then
      python3 scripts/ci-batch-ui-results.py diagnostics "${batch_args[@]}" --phase "$batch_mode" || true
    fi
    python3 scripts/ci-batch-ui-results.py failure "${batch_args[@]}" \
      --phase "$batch_mode" --exit-code "$batch_exit_status" --native-exit-code "$batch_native_status" || true
    printf '%s\n' '::error::batchCommandFailed' >&2
  fi
  return "$batch_exit_status"
}
trap batch_finish EXIT
if [[ "$batch_mode" == build ]]; then
  python3 scripts/ci-batch-ui-results.py prepare "${batch_args[@]}"
fi
batch_context=$(python3 scripts/ci-batch-ui-results.py context "${batch_args[@]}")
IFS=$'\t' read -r batch_scheme batch_sdk batch_destination <<< "$batch_context"
if [[ "$batch_mode" == build ]]; then
  set +e
  xcodebuild -project Mirror.xcodeproj -scheme "$batch_scheme" -configuration Debug \
    -sdk "$batch_sdk" -destination "$batch_destination" -jobs 2 \
    -derivedDataPath "$batch_dir/DerivedData" -parallel-testing-enabled NO -enableCodeCoverage NO \
    CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:?}" CODE_SIGNING_ALLOWED=NO \
    build-for-testing > "$batch_dir/build.log" 2>&1
  batch_native_status=$?
  set -e
  [[ "$batch_native_status" == 0 ]] || exit "$batch_native_status"
  python3 scripts/ci-batch-ui-results.py receipt-record "${batch_args[@]}"
  printf 'batch_build_ready=true\n' >> "${GITHUB_OUTPUT:?}"
  exit 0
fi
python3 scripts/ci-batch-ui-results.py receipt-verify "${batch_args[@]}"
python3 scripts/ci-batch-ui-results.py boot "${batch_args[@]}"
[[ ! -e "$batch_dir/UI.xcresult" && ! -L "$batch_dir/UI.xcresult" ]] || exit 2
set +e
xcodebuild -project Mirror.xcodeproj -scheme "$batch_scheme" -configuration Debug \
  -sdk "$batch_sdk" -destination "$batch_destination" -jobs 2 \
  -derivedDataPath "$batch_dir/DerivedData" -resultBundlePath "$batch_dir/UI.xcresult" \
  -parallel-testing-enabled NO -enableCodeCoverage NO \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:?}" CODE_SIGNING_ALLOWED=NO \
  test-without-building > "$batch_dir/test.log" 2>&1
batch_native_status=$?
set -e
[[ "$batch_native_status" == 0 ]] || exit "$batch_native_status"
xcrun xcresulttool get test-results summary --path "$batch_dir/UI.xcresult" > "$batch_dir/summary.json" 2> "$batch_dir/summary-export.stderr"
xcrun xcresulttool get test-results tests --path "$batch_dir/UI.xcresult" > "$batch_dir/tests.json" 2> "$batch_dir/tests-export.stderr"
python3 scripts/ci-batch-ui-results.py guard "${batch_args[@]}"
printf 'batch_evidence_ready=true\n' >> "${GITHUB_OUTPUT:?}"
