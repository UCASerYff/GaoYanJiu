#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
PARENT=$(mktemp -d /private/tmp/research-startup-timing.XXXXXXXX)
WORK="$PARENT/fixture.noindex"
trap 'rm -rf "$PARENT"' EXIT INT TERM
mkdir -p "$WORK/cache"
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc -swift-version 5 -parse-as-library -Onone -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$WORK/cache" "$ROOT/Sources/StartupDiagnostics.swift" "$ROOT/Sources/StartupDiagnosticsFile.swift" \
    "$ROOT/Tests/StartupDiagnosticsFileRegression.swift" -o "$WORK/StartupDiagnosticsFileRegression"
for name in readiness bounded symlink permissions unsafe-read retention concurrent-read invalid-json; do
    "$WORK/StartupDiagnosticsFileRegression" "$name" "$WORK/cases/$name"
done
echo 'Startup timing regressions passed; no App, GUI, real data or smoke test launched.'
