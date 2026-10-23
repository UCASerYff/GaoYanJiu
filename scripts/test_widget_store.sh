#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -d "$DEVELOPER_DIR" ]] || { echo 'Widget store checks require Xcode'; exit 1; }
TEST_PARENT=$(mktemp -d /private/tmp/gao-research-widget-store.XXXXXXXX)
TEST_WORK="$TEST_PARENT/fixture.noindex"
trap 'rm -rf "$TEST_PARENT"' EXIT INT TERM
# A non-APPL bundle in a nonindexed temporary tree cannot become an alternate
# installed application entry. Invoke the CLI executable directly, never open.
TEST_BUNDLE="$TEST_WORK/ResearchWidgetStoreRegression.bundle"
mkdir -p "$TEST_BUNDLE/Contents/MacOS" "$TEST_WORK/cache" "$TEST_WORK/Data" "$TEST_WORK/Tmp"
python3 - "$ROOT/Info.plist" "$TEST_BUNDLE/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    original = plistlib.load(stream)
with open(sys.argv[2], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier': original['CFBundleIdentifier'],
                  'CFBundleName': 'ResearchWidgetStoreRegression',
                  'CFBundleExecutable': 'ResearchWidgetStoreRegression',
                  'CFBundlePackageType': 'BNDL',
                  'CFBundleShortVersionString': original['CFBundleShortVersionString'],
                  'CFBundleVersion': original['CFBundleVersion']}, stream)
PY
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
SNAPSHOT="$TEST_WORK/SourceSnapshot"
mkdir -p "$SNAPSHOT/Sources" "$SNAPSHOT/GameWorld" "$SNAPSHOT/Shared" "$SNAPSHOT/Tests"
cp "$ROOT"/Sources/*.swift "$SNAPSHOT/Sources/"
cp "$ROOT"/GameWorld/*.swift "$SNAPSHOT/GameWorld/"
for shared in "$ROOT"/Shared/*.swift(N); do cp "$shared" "$SNAPSHOT/Shared/"; done
cp "$ROOT/Module.swift" "$SNAPSHOT/Module.swift"
cp "$ROOT/Tests/ResearchWidgetStoreRegression.swift" "$SNAPSHOT/Tests/ResearchWidgetStoreRegression.swift"
python3 - "$SNAPSHOT" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
sources = sorted(root.rglob('*.swift'))
for source in sources:
    digest.update(str(source.relative_to(root)).encode() + b'\0')
    digest.update(hashlib.sha256(source.read_bytes()).digest())
print(f'Widget store compiled source snapshot: {len(sources)} Swift files; SHA256 {digest.hexdigest()}')
PY
SOURCES=("$SNAPSHOT"/Sources/*.swift "$SNAPSHOT"/Shared/*.swift(N) "$SNAPSHOT"/GameWorld/*.swift "$SNAPSHOT/Module.swift")
swiftc -swift-version 5 -parse-as-library -Onone -D RESEARCH_WIDGET_STORE_REGRESSION \
    -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$TEST_WORK/cache" -load-plugin-library "$MACROS" \
    -framework SwiftUI -framework AppKit -framework WidgetKit -framework Charts \
    -framework CryptoKit -framework AppIntents -framework SceneKit -framework WebKit \
    -framework UniformTypeIdentifiers -framework Security -framework PDFKit \
    -framework QuickLookUI -framework UserNotifications -framework Combine \
    -framework CoreText -framework ImageIO -lsqlite3 \
    $SOURCES "$SNAPSHOT/Tests/ResearchWidgetStoreRegression.swift" \
    -o "$TEST_BUNDLE/Contents/MacOS/ResearchWidgetStoreRegression"
if nm -u "$TEST_BUNDLE/Contents/MacOS/ResearchWidgetStoreRegression" | /usr/bin/c++filt | \
    /usr/bin/grep -E 'OBJC_CLASS_.*NSUserDefaults|Foundation.*UserDefaults'; then
    echo 'Unsafe widget store binary: references real UserDefaults'; exit 1
fi
GAO_RESEARCH_DATA_DIR="$TEST_WORK/Data" GAOQINIANSAN_INTEGRATION_TEST=1 \
    GAO_WIDGET_STORE_TEST_ROOT="$TEST_WORK" TMPDIR="$TEST_WORK/Tmp/" \
    "$TEST_BUNDLE/Contents/MacOS/ResearchWidgetStoreRegression"
echo 'Widget store regression passed. No app, widget host, GUI or smoke test was started.'
