#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -d "$DEVELOPER_DIR" ]] || { echo 'Import test requires Xcode'; exit 1; }
TEST_WORK=$(mktemp -d "${TMPDIR:-/tmp}/gao-research-import-test.XXXXXXXX")
trap 'rm -rf "$TEST_WORK"' EXIT INT TERM
mkdir -p "$TEST_WORK/tmp" "$TEST_WORK/cache"
SDK=$(xcrun --sdk macosx --show-sdk-path)
TMPDIR="$TEST_WORK/tmp/" swiftc -swift-version 5 -parse-as-library -Onone \
    -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$TEST_WORK/cache" -framework CryptoKit \
    "$ROOT/Sources/ResearchImportJournal.swift" "$ROOT/Tests/ResearchImportRegression.swift" \
    -o "$TEST_WORK/ResearchImportRegression"
TMPDIR="$TEST_WORK/tmp/" GQ_IMPORT_TEST_ROOT="$TEST_WORK/data" \
    "$TEST_WORK/ResearchImportRegression"
[[ ! -e "$TEST_WORK/data" ]] || { echo 'Import fixture cleanup failed'; exit 1; }
