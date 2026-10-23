#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -d "$DEVELOPER_DIR" ]] || { echo 'Trash persistence checks require Xcode'; exit 1; }
TEST_PARENT=$(mktemp -d /private/tmp/gao-research-trash-persistence.XXXXXXXX)
TEST_WORK="$TEST_PARENT/fixture.noindex"
trap 'rm -rf "$TEST_PARENT"' EXIT INT TERM
# A non-APPL bundle in a nonindexed temporary tree cannot become an alternate
# installed application entry. Invoke the CLI executable directly, never open.
TEST_BUNDLE="$TEST_WORK/ResearchTrashPersistenceRegression.bundle"
mkdir -p "$TEST_BUNDLE/Contents/MacOS" "$TEST_WORK/cache" "$TEST_WORK/Data" "$TEST_WORK/Tmp"
python3 - "$ROOT/Info.plist" "$TEST_BUNDLE/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    original = plistlib.load(stream)
with open(sys.argv[2], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier': original['CFBundleIdentifier'],
                  'CFBundleName': 'ResearchTrashPersistenceRegression',
                  'CFBundleExecutable': 'ResearchTrashPersistenceRegression',
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
cp "$ROOT/Tests/ResearchTrashPersistenceRegression.swift" "$SNAPSHOT/Tests/ResearchTrashPersistenceRegression.swift"
python3 - "$SNAPSHOT" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
sources = sorted(root.rglob('*.swift'))
for source in sources:
    digest.update(str(source.relative_to(root)).encode() + b'\0')
    digest.update(hashlib.sha256(source.read_bytes()).digest())
print(f'Trash persistence compiled source snapshot: {len(sources)} Swift files; SHA256 {digest.hexdigest()}')
PY
COPY_FAULT_SEAM=0
for requested_case in "$@"; do
    if [[ "$requested_case" == edge.copy-* ]]; then COPY_FAULT_SEAM=1; fi
done
if (( COPY_FAULT_SEAM )); then
    python3 - "$SNAPSHOT/Sources/RecycleBinStore.swift" <<'PYCOPYFAULT'
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
original = path.read_bytes()
needle = "                try FileManager.default.copyItem(at: source, to: destination)"
text = original.decode()
assert text.count(needle) == 1, "Review copy fault seam: production boundary changed"
replacement = "                try ResearchTrashCopyFault.beforeCopy(source: source, destination: destination)\n" + needle
path.write_text(text.replace(needle, replacement))
print("Copy fault seam: final production RecycleBinStore SHA256 " + hashlib.sha256(original).hexdigest())
print("Copy fault seam: private injected snapshot SHA256 " + hashlib.sha256(path.read_bytes()).hexdigest())
print("Copy fault seam changes only the line before actual copyItem; catch and safety logic unchanged.")
PYCOPYFAULT
fi
SOURCES=("$SNAPSHOT"/Sources/*.swift "$SNAPSHOT"/Shared/*.swift(N) "$SNAPSHOT"/GameWorld/*.swift "$SNAPSHOT/Module.swift")
swiftc -swift-version 5 -parse-as-library -Onone -D RESEARCH_WIDGET_STORE_REGRESSION \
    -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$TEST_WORK/cache" -load-plugin-library "$MACROS" \
    -framework SwiftUI -framework AppKit -framework WidgetKit -framework Charts \
    -framework CryptoKit -framework AppIntents -framework SceneKit -framework WebKit \
    -framework UniformTypeIdentifiers -framework Security -framework PDFKit \
    -framework QuickLookUI -framework UserNotifications -framework Combine \
    -framework CoreText -framework ImageIO -lsqlite3 \
    $SOURCES "$SNAPSHOT/Tests/ResearchTrashPersistenceRegression.swift" \
    -o "$TEST_BUNDLE/Contents/MacOS/ResearchTrashPersistenceRegression"
if nm -u "$TEST_BUNDLE/Contents/MacOS/ResearchTrashPersistenceRegression" | /usr/bin/c++filt | \
    /usr/bin/grep -E 'OBJC_CLASS_.*NSUserDefaults|Foundation.*UserDefaults'; then
    echo 'Unsafe trash persistence binary: references real UserDefaults'; exit 1
fi
CASES=()
for kind in work certificate document folder workAttachment certificateAttachment; do
    for operation in delete restore; do
        for fault in before after success missing; do CASES+=("$kind.$operation.$fault"); done
    done
done
for fault in before after success; do
    for operation in permanent empty expiry; do CASES+=("purge.$operation.$fault"); done
done
CASES+=(noPayload.delete.success noPayload.restore.success edge.unsaved-memory edge.external-cas edge.unreadable-after edge.changed-source-cleanup edge.symlink edge.malformed-id edge.folder-conflict)
if (( $# )); then CASES=("$@"); fi
for case_name in $CASES; do
    CASE_ROOT="$TEST_WORK/cases/$case_name/fixture.noindex"
    mkdir -p "$CASE_ROOT/Data" "$CASE_ROOT/Tmp" "$CASE_ROOT/Widget"
    GAO_RESEARCH_DATA_DIR="$CASE_ROOT/Data" GAOQINIANSAN_INTEGRATION_TEST=1 \
        GAO_WIDGET_STORE_TEST_ROOT="$CASE_ROOT" TMPDIR="$CASE_ROOT/Tmp/" \
        "$TEST_BUNDLE/Contents/MacOS/ResearchTrashPersistenceRegression" "$case_name"
done
echo 'Trash persistence regression passed. No app, widget host, GUI or smoke test was started.'
