#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(printenv GITHUB_ACTIONS || true)" != "true" ]]; then
  printf '%s\n' '성능 baseline은 GitHub Actions 러너에서만 실행합니다.' >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' '실제 Core Data SQLite baseline은 macOS 러너가 필요합니다.' >&2
  exit 1
fi

task_result_directory="$PWD/.build/ci-performance"
task_scratch_directory="$PWD/.build/performance-probe"
mkdir -p "$task_result_directory"
task_python="$(command -v python3)"

# 허용한 환경 필드와 실제 SDK 출력만 보존한다. 환경 변수 전체를 덤프하지 않는다.
"$task_python" - "$task_result_directory/environment.json" <<'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path

def output(*command):
    return subprocess.check_output(command, text=True).strip()

baseline = json.loads(Path("development-baseline.json").read_text())
expected = baseline["observedToolchain"]
host_os = output("sw_vers", "-productVersion")
xcode = output("xcodebuild", "-version")
swift = output("xcrun", "swift", "--version")
sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-version")
swift_version = re.search(r"Apple Swift version (\d+\.\d+)(?:\.\d+)?\b", swift)
commit = os.environ.get("GITHUB_SHA", "")
report = {
    "configuration": "Release",
    "hostOS": host_os,
    "hostArchitecture": output("uname", "-m"),
    "machineModel": output("sysctl", "-n", "hw.model"),
    "memoryBytes": output("sysctl", "-n", "hw.memsize"),
    "logicalCPUCount": output("sysctl", "-n", "hw.logicalcpu"),
    "xcode": xcode,
    "swift": swift,
    "macOSSDK": sdk,
    "commit": commit,
    "runnerLabel": "xcode-27",
    "runnerName": os.environ.get("RUNNER_NAME", "unknown"),
    "runnerOS": os.environ.get("RUNNER_OS", "unknown"),
    "runID": os.environ.get("GITHUB_RUN_ID", "unknown"),
    "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT", "unknown"),
}
Path(sys.argv[1]).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
valid = (
    int(host_os.split(".")[0]) >= 27
    and f"Xcode {expected['xcode']}" in xcode.splitlines()
    and f"Build version {expected['xcodeBuild']}" in xcode.splitlines()
    and swift_version is not None
    and swift_version.group(1) == expected["swift"]
    and sdk == expected["macOSSDK"]
    and re.fullmatch(r"[0-9a-f]{40}", commit) is not None
)
if not valid:
    raise SystemExit("확정한 OS/Xcode/Swift/SDK/원격 commit과 실제 환경이 일치하지 않습니다.")
PY

task_build_start="$SECONDS"
if ! swift build --configuration release --scratch-path "$task_scratch_directory" --product MirrorStoreProbe \
  > "$task_result_directory/build.log" 2>&1; then
  printf '%s\n' '::error::성능 helper Release 빌드 실패: build.log를 확인하세요.'
  tail -n 80 "$task_result_directory/build.log"
  exit 1
fi
task_build_seconds="$((SECONDS - task_build_start))"
"$task_python" - "$task_result_directory/environment.json" "$task_build_seconds" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
report = json.loads(path.read_text())
report["releaseBuildSeconds"] = sys.argv[2]
path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
PY

task_binary_directory="$(swift build --configuration release --scratch-path "$task_scratch_directory" --show-bin-path)"
task_helper="$task_binary_directory/MirrorStoreProbe"
if [[ ! -x "$task_helper" ]]; then
  printf '%s\n' '::error::명시적으로 빌드한 성능 helper가 없습니다.'
  exit 1
fi
task_temporary_base="$(printenv RUNNER_TEMP || true)"
if [[ -z "$task_temporary_base" ]]; then task_temporary_base="/tmp"; fi
task_directory="$(mktemp -d "$task_temporary_base/mirror-performance.XXXXXX")"
trap 'rm -rf -- "$task_directory"' EXIT
task_store_directory="$task_directory/stores"
mkdir -p "$task_store_directory"

# 실제 SQLite와 입력/export는 이 임시 경로에만 둔다. stderr 원문은 공개 artifact에서 제외한다.
task_result=0
"$task_helper" benchmark "$task_store_directory" "$task_result_directory/report.json" \
  "$task_result_directory/environment.json" > "$task_result_directory/run.log" 2> "$task_directory/private-stderr.log" \
  || task_result="$?"

# artifact 다운로드가 제한돼도 실제 표본을 check annotations에서 읽을 수 있게 한다.
# 출력은 숫자·고정 상태·검증 플래그·허용한 도구 환경으로 제한한다.
if [[ -f "$task_result_directory/report.json" ]]; then
  "$task_python" - "$task_result_directory/report.json" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
allowed = (
    "formatVersion", "scope", "configuration", "clock", "semanticInstant", "timeZone",
    "status", "stage", "expectedInitialTasks", "expectedInitialRecords", "recordsPerInitialTask",
    "plannedSnapshotSamples", "plannedCommandSamples", "plannedExportSamples", "commandKind",
    "percentileMethod", "measurementOrder", "snapshotCacheCondition",
    "preparationMilliseconds", "roundTripMilliseconds", "initialImport", "initialCounts", "finalCounts",
    "snapshot", "singleCommand", "exportArchive", "commandResultCounts", "archiveBytes",
    "archiveExceedsFormer32MiBLimit", "localCommandTargetMilliseconds",
    "localCommandP95TargetMetOnRunner", "allLocalCommandSamplesMetTargetOnRunner",
    "realDeviceAcceptanceEvaluated", "widgetDisplayMeasured", "q086AcceptanceResult", "roundTrip",
)
safe = {key: report[key] for key in allowed if key in report}
safe["calendar"] = {
    key: report.get("calendar", {}).get(key)
    for key in ("status", "requiredEvents", "actualEventKitQueryMeasured")
}
environment_fields = (
    "configuration", "hostOS", "hostArchitecture", "machineModel", "memoryBytes", "logicalCPUCount",
    "xcode", "swift", "macOSSDK", "commit", "runnerLabel", "runnerName", "runnerOS",
    "runID", "runAttempt", "releaseBuildSeconds",
)
safe["environment"] = {
    key: report.get("environment", {}).get(key)
    for key in environment_fields
}
message = json.dumps(safe, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print("::notice title=Production performance baseline::" + message)
PY
else
  printf '%s\n' '::warning::성능 report.json이 생성되지 않았습니다. 완료나 통과로 판정할 수 없습니다.'
fi
if [[ "$task_result" -ne 0 ]]; then
  printf '%s\n' '::error::성능 baseline 또는 전체 archive 왕복 검증 실패: report.json의 stage를 확인하세요.'
  exit "$task_result"
fi
printf '%s\n' '생산 SQLite baseline과 전체 archive 두 번 가져오기 검증을 완료했습니다. 실기기 수용 판정은 실행하지 않았습니다.'
