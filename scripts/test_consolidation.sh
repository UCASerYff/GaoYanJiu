#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TEST_PARENT=$(mktemp -d /private/tmp/research-integration.XXXXXXXX)
TEST_WORK="$TEST_PARENT/fixture.noindex"
trap 'rm -rf "$TEST_PARENT"' EXIT INT TERM
SNAPSHOT="$TEST_WORK/SourceSnapshot"
TEST_BUNDLE="$TEST_WORK/ResearchIntegrationRegression.bundle"
mkdir -p "$SNAPSHOT/Sources" "$SNAPSHOT/GameWorld" "$SNAPSHOT/Shared" "$SNAPSHOT/Tests" "$TEST_BUNDLE/Contents/MacOS" "$TEST_WORK/cache"
cp "$ROOT"/Sources/*.swift "$SNAPSHOT/Sources/"
cp "$ROOT"/GameWorld/*.swift "$SNAPSHOT/GameWorld/"
for shared in "$ROOT"/Shared/*.swift(N); do cp "$shared" "$SNAPSHOT/Shared/"; done
cp "$ROOT/Module.swift" "$SNAPSHOT/Module.swift"
for name in ResearchTrashPersistenceRegression StartupMaintenanceRegression ResearchIntegrationRegression; do
    cp "$ROOT/Tests/$name.swift" "$SNAPSHOT/Tests/"
done
python3 - "$ROOT/Info.plist" "$TEST_BUNDLE/Contents/Info.plist" "$SNAPSHOT" <<'PY'
import hashlib,pathlib,plistlib,sys
info=plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps({'CFBundleIdentifier':info['CFBundleIdentifier'],'CFBundleName':'ResearchIntegrationRegression','CFBundleExecutable':'ResearchIntegrationRegression','CFBundlePackageType':'BNDL','CFBundleShortVersionString':info['CFBundleShortVersionString'],'CFBundleVersion':info['CFBundleVersion']}))
root=pathlib.Path(sys.argv[3]);digest=hashlib.sha256()
for p in sorted(root.rglob('*.swift')):
    digest.update(str(p.relative_to(root)).encode()+b'\0'+hashlib.sha256(p.read_bytes()).digest())
print('Consolidation immutable production/test snapshot SHA256 '+digest.hexdigest(),flush=True)
PY
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
SOURCES=("$SNAPSHOT"/Sources/*.swift "$SNAPSHOT"/Shared/*.swift(N) "$SNAPSHOT"/GameWorld/*.swift "$SNAPSHOT/Module.swift")
swiftc -swift-version 5 -parse-as-library -Onone -D RESEARCH_WIDGET_STORE_REGRESSION -D RESEARCH_INTEGRATION_COMBINED \
    -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$TEST_WORK/cache" -load-plugin-library "$MACROS" \
    -framework SwiftUI -framework AppKit -framework WidgetKit -framework Charts -framework CryptoKit -framework AppIntents \
    -framework SceneKit -framework WebKit -framework UniformTypeIdentifiers -framework Security -framework PDFKit \
    -framework QuickLookUI -framework UserNotifications -framework Combine -framework CoreText -framework ImageIO -lsqlite3 \
    $SOURCES "$SNAPSHOT"/Tests/*.swift -o "$TEST_BUNDLE/Contents/MacOS/ResearchIntegrationRegression"
if nm -u "$TEST_BUNDLE/Contents/MacOS/ResearchIntegrationRegression" | /usr/bin/c++filt | /usr/bin/grep -E 'OBJC_CLASS_.*NSUserDefaults|Foundation.*UserDefaults'; then
    echo 'Unsafe test binary references real preferences'; exit 1
fi
for name in funding.readonly startup; do
    CASE_ROOT="$TEST_WORK/cases/$name/fixture.noindex"
    mkdir -p "$CASE_ROOT/Tmp" "$CASE_ROOT/Widget"
    if [[ "$name" == funding.readonly ]]; then DATA_ROOT="$CASE_ROOT/Data"; mkdir -p "$DATA_ROOT"; else DATA_ROOT="$CASE_ROOT/fixtures/unusedData"; fi
    GAO_RESEARCH_DATA_DIR="$DATA_ROOT" GAOQINIANSAN_INTEGRATION_TEST=1 \
        GAO_WIDGET_STORE_TEST_ROOT="$CASE_ROOT" GAO_STARTUP_REGRESSION_ROOT="$CASE_ROOT/fixtures" TMPDIR="$CASE_ROOT/Tmp/" \
        "$TEST_BUNDLE/Contents/MacOS/ResearchIntegrationRegression" "$name"
done
echo 'New consolidation regressions passed; no app, GUI, real preferences or smoke test launched.'
