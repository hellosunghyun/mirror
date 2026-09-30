#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Mirror"
BUNDLE_ID="com.baserize.mirror.mac"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

case "$MODE" in
  run|--debug|--logs|--telemetry|--verify) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Mac 앱 실행에는 macOS와 Xcode 27 이상이 필요합니다. 테스트는 GitHub Actions에서 실행하세요." >&2
  exit 1
fi

MACOS_SDK="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${MACOS_SDK%%.*}" -lt 27 ]]; then
  echo "macOS 27 SDK가 필요합니다. xcode-select로 Xcode 27 이상을 선택하세요." >&2
  exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/Mirror.xcodeproj" \
  -scheme MirrorMac \
  -configuration Debug \
  -sdk macosx \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    for attempt in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "미러 앱 프로세스를 확인하지 못했습니다." >&2
    exit 1
    ;;
esac
