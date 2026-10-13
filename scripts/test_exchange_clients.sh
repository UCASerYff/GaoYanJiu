#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TEST_WORK=$(mktemp -d "${TMPDIR:-/tmp}/gao-research-exchange-clients.XXXXXXXX")
trap 'rm -rf "$TEST_WORK"' EXIT INT TERM
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc -swift-version 5 -parse-as-library -Onone -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$TEST_WORK/cache" \
    -framework AppKit -framework CryptoKit -framework UniformTypeIdentifiers -framework Security \
    "$ROOT/Sources/GaoActionV1.swift" "$ROOT/Sources/ResearchExchangeClients.swift" \
    "$ROOT/Tests/ResearchExchangeClientsRegression.swift" -o "$TEST_WORK/ResearchExchangeClientsRegression"
# These fixtures inject a provider lookup and use only this temporary root.
"$TEST_WORK/ResearchExchangeClientsRegression" "$TEST_WORK/fixture-data"
[[ ! -e "$TEST_WORK/fixture-data" ]] || { echo 'Fixture cleanup failed'; exit 1; }
