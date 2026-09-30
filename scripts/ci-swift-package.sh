#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/ci-swift .build/mirror-test-fixtures
cp postpone-app-docs/fixtures/domain-cases.json .build/mirror-test-fixtures/domain-cases.json
export MIRROR_FIXTURE_PATH="$PWD/.build/mirror-test-fixtures/domain-cases.json"
export NO_COLOR=1

if swift test --parallel 2>&1 | tee .build/ci-swift/test.log; then
  python3 scripts/ci_results.py swift .build/ci-swift/test.log
else
  test_status=$?
  python3 scripts/ci_results.py diagnostics .build/ci-swift/test.log || true
  exit "$test_status"
fi
