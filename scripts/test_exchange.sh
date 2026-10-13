#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEST_ROOT=$(mktemp -d /private/tmp/research-exchange-build.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -O \
    -module-cache-path "$TEST_ROOT/cache" \
    "$ROOT/Sources/GaoActionV1.swift" "$ROOT/Tests/GaoActionFixtures.swift" \
    -o "$TEST_ROOT/gaoaction-fixtures"
"$TEST_ROOT/gaoaction-fixtures"
