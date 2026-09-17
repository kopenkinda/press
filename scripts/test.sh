#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
./scripts/prepare-runtime.sh
export PRESS_TEST_FIXTURES="$PWD/.build/test-fixtures"
python3 Tests/make-fixtures.py "$PRESS_TEST_FIXTURES" "$PWD/.build/7zip/7zz"
options=(--scratch-path .build/tests)
xcrun swift test "${options[@]}" "$@"
