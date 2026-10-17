#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -d "$DEVELOPER_DIR" ]] || { echo 'Widget pipeline tests require Xcode'; exit 1; }
TEST_WORK=$(mktemp -d /private/tmp/gao-research-widget-test.XXXXXXXX)
trap 'rm -rf "$TEST_WORK"' EXIT INT TERM
mkdir -p "$TEST_WORK/cache" "$TEST_WORK/SourceSnapshot/Sources" "$TEST_WORK/SourceSnapshot/GameWorld" "$TEST_WORK/SourceSnapshot/Shared" "$TEST_WORK/Data"
SNAPSHOT="$TEST_WORK/SourceSnapshot"
cp "$ROOT"/Sources/*.swift "$SNAPSHOT/Sources/"
cp "$ROOT"/GameWorld/*.swift "$SNAPSHOT/GameWorld/"
for shared in "$ROOT"/Shared/*.swift(N); do cp "$shared" "$SNAPSHOT/Shared/"; done
cp "$ROOT/Module.swift" "$SNAPSHOT/Module.swift"
cp "$ROOT/Widgets/ResearchWidgets.swift" "$SNAPSHOT/ResearchWidgets.swift"
cp "$ROOT/Tests/ResearchWidgetFixtures.swift" "$SNAPSHOT/ResearchWidgetFixtures.swift"
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
SOURCES=("$SNAPSHOT"/Sources/*.swift "$SNAPSHOT"/Shared/*.swift(N) "$SNAPSHOT"/GameWorld/*.swift "$SNAPSHOT/Module.swift")
# A plain CLI executable has no APPL/real-host registration metadata.
swiftc -swift-version 5 -parse-as-library -Onone -D WIDGET_LAYOUT_TEST \
    -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$TEST_WORK/cache" \
    -load-plugin-library "$MACROS" -framework SwiftUI -framework AppKit -framework WidgetKit \
    -framework Charts -framework CryptoKit -framework AppIntents -framework SceneKit -framework WebKit \
    -framework UniformTypeIdentifiers -framework Security -framework PDFKit -framework QuickLookUI \
    -framework UserNotifications -framework Combine -framework CoreText -framework ImageIO -lsqlite3 \
    $SOURCES "$SNAPSHOT/ResearchWidgets.swift" "$SNAPSHOT/ResearchWidgetFixtures.swift" -o "$TEST_WORK/ResearchWidgetFixtures"
if nm -u "$TEST_WORK/ResearchWidgetFixtures" | /usr/bin/c++filt | \
    /usr/bin/grep -E 'OBJC_CLASS_.*NSUserDefaults|Foundation.*UserDefaults'; then
    echo 'Unsafe widget test binary: references real UserDefaults'; exit 1
fi
GAO_WIDGET_TEST_ROOT="$TEST_WORK" GAO_RESEARCH_DATA_DIR="$TEST_WORK/Data" GAOQINIANSAN_INTEGRATION_TEST=1 \
    "$TEST_WORK/ResearchWidgetFixtures"
