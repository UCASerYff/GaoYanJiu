#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$ROOT/build.noindex"
export GAO_BUILD_DIR="$BUILD"
export GAO_VERIFY_ONLY=0
APP="$BUILD/搞研究.app"
SIGNING_IDENTITY=${GAO_SIGNING_IDENTITY:-A15B2B2D22B018CBC842063C9A8A589946647524}
[[ -d "$DEVELOPER_DIR" ]] || { echo '需要完整 Xcode';exit 1; }
mkdir -p "$BUILD/cache" "$BUILD/icon.iconset"
if [[ "${1:-}" != "--skip-frameworks" ]]; then
    "$ROOT/scripts/build_framework.sh" > "$BUILD/framework-build.log" 2>&1 || { tail -60 "$BUILD/framework-build.log";exit 1;}
    "$ROOT/scripts/build_widgets.sh" > "$BUILD/widget-build.log" 2>&1 || { tail -60 "$BUILD/widget-build.log";exit 1;}
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/PlugIns"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/Resources/AcademicAchievementManagerIcon.png" --out "$BUILD/icon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size*2))
    sips -z $double $double "$ROOT/Resources/AcademicAchievementManagerIcon.png" --out "$BUILD/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 "$ROOT/scripts/pack_icon.py" "$BUILD/icon.iconset" "$APP/Contents/Resources/AcademicAchievementManager.icns"
/bin/bash "$ROOT/scripts/compile_host.sh" "$BUILD" "$APP/Contents/MacOS/AcademicAchievementManager"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AcademicAchievementManagerIcon.png" "$APP/Contents/Resources/"
cp "$ROOT/Resources/GaoCapabilities.json" "$APP/Contents/Resources/"
ditto "$BUILD/Frameworks/Research.framework" "$APP/Contents/Frameworks/Research.framework"
for helper in "$APP"/Contents/Frameworks/Research.framework/Versions/A/Resources/UsageEngine/tokscale(N); do codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$helper"; done
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Frameworks/Research.framework"
ditto "$BUILD/PlugIns/ResearchWidgets.appex" "$APP/Contents/PlugIns/ResearchWidgets.appex"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT/Widget.entitlements" "$APP/Contents/PlugIns/ResearchWidgets.appex"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT/App.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
