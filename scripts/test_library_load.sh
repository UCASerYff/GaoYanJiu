#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
# No arguments retains the original library-load suite. The focused OCR cases
# must be requested explicitly and never starts an application/provider.
TEST_ARGUMENTS=("$@")
if (( $# != 0 )); then
    [[ $# == 2 && "$1" == '--case' && ( "$2" == 'ocr-revision-ordering' || "$2" == 'ocr-result-repack' || "$2" == 'completed-ocr-ordering' ) ]] || {
        echo 'Usage: scripts/test_library_load.sh [--case ocr-revision-ordering|ocr-result-repack|completed-ocr-ordering]'; exit 2
    }
fi
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -d "$DEVELOPER_DIR" ]] || { echo 'Library load safety tests require Xcode'; exit 1; }
TEST_WORK=$(mktemp -d /private/tmp/gao-research-library-load-test.XXXXXXXX)
trap 'rm -rf "$TEST_WORK"' EXIT INT TERM
# A CLI fixture must not advertise an APPL host under the production identity:
# LaunchServices can discover temporary .app hosts and displace the real Widget.
TEST_BUNDLE="$TEST_WORK/LibraryLoadSafetyRegression.bundle"
mkdir -p "$TEST_BUNDLE/Contents/MacOS" "$TEST_WORK/cache" "$TEST_WORK/Tmp"
python3 - "$ROOT/Info.plist" "$TEST_BUNDLE/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    original = plistlib.load(stream)
with open(sys.argv[2], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier': original['CFBundleIdentifier'],
                  'CFBundleName': 'LibraryLoadSafetyRegression',
                  'CFBundleExecutable': 'LibraryLoadSafetyRegression',
                  'CFBundlePackageType': 'BNDL',
                  'CFBundleShortVersionString': original['CFBundleShortVersionString'],
                  'CFBundleVersion': original['CFBundleVersion']}, stream)
PY
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
# Compile byte-for-byte copies of the current production sources. Other agents
# may continue editing the workspace while Swift compiles; immutable inputs
# prevent a mixed build or "input file modified during build" failure.
SNAPSHOT="$TEST_WORK/SourceSnapshot"
mkdir -p "$SNAPSHOT/Sources" "$SNAPSHOT/GameWorld" "$SNAPSHOT/Tests" "$SNAPSHOT/Shared"
cp "$ROOT"/Sources/*.swift "$SNAPSHOT/Sources/"
cp "$ROOT"/GameWorld/*.swift "$SNAPSHOT/GameWorld/"
for shared in "$ROOT"/Shared/*.swift(N); do cp "$shared" "$SNAPSHOT/Shared/"; done
cp "$ROOT/Module.swift" "$SNAPSHOT/Module.swift"
cp "$ROOT/Tests/LibraryLoadSafetyRegression.swift" "$SNAPSHOT/Tests/LibraryLoadSafetyRegression.swift"
SOURCES=("$SNAPSHOT"/Sources/*.swift "$SNAPSHOT"/Shared/*.swift(N) "$SNAPSHOT"/GameWorld/*.swift "$SNAPSHOT/Module.swift")
swiftc -swift-version 5 -parse-as-library -Onone -D LIBRARY_LOAD_SAFETY_TEST \
    -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$TEST_WORK/cache" -load-plugin-library "$MACROS" \
    -framework SwiftUI -framework AppKit -framework WidgetKit -framework Charts \
    -framework CryptoKit -framework AppIntents -framework SceneKit -framework WebKit \
    -framework UniformTypeIdentifiers -framework Security -framework PDFKit \
    -framework QuickLookUI -framework UserNotifications -framework Combine \
    -framework CoreText -framework ImageIO -lsqlite3 \
    $SOURCES "$SNAPSHOT/Tests/LibraryLoadSafetyRegression.swift" \
    -o "$TEST_BUNDLE/Contents/MacOS/LibraryLoadSafetyRegression"
# Every preference access in production Sources must bind to the test-only
# in-memory defaults, never the user's actual preference databases.
if nm -u "$TEST_BUNDLE/Contents/MacOS/LibraryLoadSafetyRegression" | /usr/bin/c++filt | \
    /usr/bin/grep -E 'OBJC_CLASS_.*NSUserDefaults|Foundation.*UserDefaults'; then
    echo 'Unsafe product test binary: references real UserDefaults'; exit 1
fi
GAO_RESEARCH_DATA_DIR="$TEST_WORK/Data" GAOQINIANSAN_INTEGRATION_TEST=1 \
    GAO_LIBRARY_LOAD_TEST_ROOT="$TEST_WORK/fixtures" TMPDIR="$TEST_WORK/Tmp/" \
    "$TEST_BUNDLE/Contents/MacOS/LibraryLoadSafetyRegression" "${TEST_ARGUMENTS[@]}"
echo 'Library load safety regression passed. No GUI or smoke test was performed.'
