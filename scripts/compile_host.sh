#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $# -ne 2 ]]; then
    echo 'Usage: compile_host.sh BUILD_DIR OUTPUT_EXECUTABLE' >&2
    exit 2
fi
BUILD=$1
OUTPUT=$2
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
[[ -f "$MACROS" ]] || { echo "Missing SwiftUI macro plugin: $MACROS" >&2; exit 1; }
mkdir -p "$BUILD/cache"
swiftc -swift-version 5 -parse-as-library -O -sdk "$SDK" -target arm64-apple-macosx14.0 \
    -module-cache-path "$BUILD/cache" -load-plugin-library "$MACROS" \
    -F "$BUILD/Frameworks" -framework Research -framework AppKit -framework SwiftUI \
    -framework UserNotifications -framework CryptoKit -lsqlite3 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$ROOT/Host/"*.swift -o "$OUTPUT"
