#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo 'Run this verification on an arm64 macOS runner.' >&2
    exit 1
fi
if [[ -z ${DEVELOPER_DIR:-} ]]; then
    preferred=/Applications/Xcode_26.3.app/Contents/Developer
    if [[ -x "$preferred/usr/bin/xcodebuild" ]]; then
        DEVELOPER_DIR=$preferred
    elif ! DEVELOPER_DIR=$(xcode-select --print-path); then
        echo '找不到 Xcode。请安装完整 Xcode 或显式设置 DEVELOPER_DIR。' >&2
        exit 1
    fi
fi
DEVELOPER_DIR=${DEVELOPER_DIR%/}
if [[ $DEVELOPER_DIR == *.app ]]; then
    DEVELOPER_DIR=$DEVELOPER_DIR/Contents/Developer
fi
export DEVELOPER_DIR
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo "完整 Xcode 工具链不可用：$DEVELOPER_DIR" >&2
    exit 1
fi
echo "DEVELOPER_DIR=$DEVELOPER_DIR"
xcrun xcodebuild -version
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
sdk_major=${sdk_version%%.*}
if [[ ! $sdk_major =~ ^[1-9][0-9]*$ ]] || (( sdk_major < 26 )); then
    echo "验证需要 macOS 26 或更新版本的 SDK，当前为 $sdk_version。请设置 DEVELOPER_DIR 指向合适的 Xcode。" >&2
    exit 1
fi
echo "macOS SDK $sdk_version"
WORK=$(mktemp -d /private/tmp/gao-research-macos-verify.XXXXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export GAO_BUILD_DIR="$WORK/build"
export GAO_VERIFY_ONLY=1
mkdir -p "$GAO_BUILD_DIR" "$WORK/host"

# Compile the same framework, host executable, and WidgetKit extension as production.
# There is deliberately no APPL bundle around the host and no installation or registration.
/bin/zsh "$ROOT/scripts/build_framework.sh"
/bin/zsh "$ROOT/scripts/build_widgets.sh"
/bin/bash "$ROOT/scripts/compile_host.sh" "$GAO_BUILD_DIR" "$WORK/host/AcademicAchievementManager"
FRAMEWORK="$GAO_BUILD_DIR/Frameworks/Research.framework/Versions/A"
WIDGET="$GAO_BUILD_DIR/PlugIns/ResearchWidgets.appex/Contents"
for binary in "$WORK/host/AcademicAchievementManager" "$FRAMEWORK/Research" "$WIDGET/MacOS/ResearchWidgets"; do
    [[ $(xcrun lipo -archs "$binary") == arm64 ]] || { echo "Unexpected architecture: $binary" >&2; exit 1; }
done
python3 - "$ROOT/Info.plist" "$ROOT/Widgets/Info.plist" "$FRAMEWORK/Resources/Info.plist" "$WIDGET/Info.plist" <<'PY'
import pathlib
import plistlib
import sys

host, widget_source, framework, widget = [
    plistlib.loads(pathlib.Path(path).read_bytes()) for path in sys.argv[1:]
]
keys = ("CFBundleShortVersionString", "CFBundleVersion")
expected = tuple(host[key] for key in keys)
for name, metadata in (("Widget source", widget_source), ("Research framework", framework), ("built Widget", widget)):
    if tuple(metadata[key] for key in keys) != expected:
        raise SystemExit(f"{name} version differs from the host metadata")
assert widget["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
print(f"arm64 host, framework and WidgetKit extension use macOS {expected[0]} (build {expected[1]})")
PY

/bin/zsh "$ROOT/scripts/test_exchange_clients.sh"
/bin/zsh "$ROOT/scripts/test_exchange_clients.sh" --case ocr-result-repack
/bin/zsh "$ROOT/scripts/test_startup_diagnostics.sh"
/bin/zsh "$ROOT/scripts/test_product.sh" submission-actions new-version ocr-managed-result ocr-json-managed-result
/bin/zsh "$ROOT/scripts/test_library_load.sh" --case ocr-auto-return
/bin/zsh "$ROOT/scripts/test_library_load.sh" --case ocr-result-repack
if [[ -n ${GAO_CAOZUO_SOURCE:-} ]]; then
    /bin/bash "$ROOT/scripts/test_ocr_return_interop.sh"
fi
