#!/bin/zsh
set -euo pipefail
setopt POSIX_TRAPS
ROOT=${0:A:h:h}
TARGET="/Applications/搞研究.app"
APP_ID="com.academic-achievement.manager"
WIDGET_ID="$APP_ID.widgets"
TEAM="5G96498KGJ"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PLISTBUDDY=/usr/libexec/PlistBuddy
NEW_WIDGET="$TARGET/Contents/PlugIns/ResearchWidgets.appex"
LOCK="$ROOT/.install-lock.noindex"
STAGE=""
SAFETY=""
TRANSACTION_STARTED=0
OLD_MOVED=0
TARGET_WRITTEN=0
COMMITTED=0
OLD_ELECTION=default

# Callers explicitly exit/return. A failed function under zsh ERR_EXIT can
# bypass EXIT traps, which would leave a replacement without its rollback.
fail() { print -u2 -- "$1"; }
plist_value() { "$PLISTBUDDY" -c "Print :$2" "$1/Contents/Info.plist"; }

# Leave recovery copies until the caller has verified business data and widgets.
# This script changes only application bundles and their registrations.
finish_install() {
    local exit_code=$1 rollback_ok=1
    set +e
    trap - EXIT INT TERM
    if (( TRANSACTION_STARTED && ! COMMITTED )); then
        print -u2 -- '安装未完成，正在恢复旧程序和小组件登记…'
        if (( TARGET_WRITTEN )); then
            pluginkit -r "$NEW_WIDGET" >/dev/null 2>&1 || true
            "$LSREGISTER" -u "$TARGET" >/dev/null 2>&1 || true
            /bin/rm -rf "$TARGET" || rollback_ok=0
        fi
        if (( OLD_MOVED )); then
            if [[ ! -e "$TARGET" && -d "$SAFETY" ]]; then
                /bin/mv "$SAFETY" "$TARGET" || rollback_ok=0
            else
                rollback_ok=0
            fi
        fi
        if [[ -d "$TARGET" ]]; then
            "$LSREGISTER" -f -R "$TARGET" || rollback_ok=0
            if [[ -d "$NEW_WIDGET" ]]; then
                pluginkit -a "$NEW_WIDGET" || rollback_ok=0
                pluginkit -e "$OLD_ELECTION" -i "$WIDGET_ID" || rollback_ok=0
            fi
        fi
        if (( ! rollback_ok )); then
            print -u2 -- "自动回滚未完全成功；请保留恢复副本：$SAFETY"
            exit_code=1
        fi
    fi
    [[ -z "$STAGE" ]] || /bin/rm -rf "$STAGE"
    /bin/rmdir "$LOCK" 2>/dev/null || true
    exit "$exit_code"
}

mkdir "$LOCK" 2>/dev/null || { fail '另一个安装正在进行；确认其结束后再安装'; exit 1; }
trap 'finish_install $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

VERSION=$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
NUMBER=$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$ROOT/Info.plist")
SOURCE=${GAO_INSTALL_APP:-"$ROOT/build.noindex/搞研究.app"}
if [[ ! -d "$SOURCE" ]]; then
    [[ -z "${GAO_INSTALL_APP:-}" ]] || { fail '指定安装包不存在'; exit 1; }
    STAGE=$(mktemp -d "$ROOT/.install.noindex.XXXXXXXX")
    (cd "$ROOT/dist"; shasum -a 256 -c "GaoYanJiu-$VERSION.zip.sha256")
    ditto -x -k "$ROOT/dist/GaoYanJiu-$VERSION.zip" "$STAGE"
    SOURCE="$STAGE/搞研究.app"
fi

verify_bundle() {
    local app=$1 widget="$1/Contents/PlugIns/ResearchWidgets.appex" widget_exec
    [[ -d "$app" && ! -L "$app" && -d "$widget" && ! -L "$widget" ]] || { fail '安装包或小组件缺失'; return 1; }
    [[ "$(plist_value "$app" CFBundleIdentifier)" == "$APP_ID" ]] || { fail '应用标识不匹配'; return 1; }
    [[ "$(plist_value "$widget" CFBundleIdentifier)" == "$WIDGET_ID" ]] || { fail '小组件标识不匹配'; return 1; }
    [[ "$(plist_value "$app" CFBundleShortVersionString)" == "$VERSION" && "$(plist_value "$app" CFBundleVersion)" == "$NUMBER" ]] || { fail '构建版本/构建号与源码不一致，请重新构建'; return 1; }
    [[ "$(plist_value "$widget" CFBundleShortVersionString)" == "$VERSION" && "$(plist_value "$widget" CFBundleVersion)" == "$NUMBER" ]] || { fail '小组件版本/构建号与应用不一致'; return 1; }
    [[ "$(plist_value "$widget" NSExtension:NSExtensionPointIdentifier)" == 'com.apple.widgetkit-extension' ]] || { fail '小组件扩展类型不正确'; return 1; }
    [[ "$(plist_value "$widget" CFBundlePackageType)" == 'XPC!' ]] || { fail '小组件包类型不正确'; return 1; }
    codesign --verify --deep --strict "$app" || return 1
    [[ "$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM" ]] || { fail '应用需要团队签名'; return 1; }
    [[ "$(codesign -dv "$widget" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM" ]] || { fail '小组件需要相同团队签名'; return 1; }
    python3 - "$app" "$widget" "$TEAM.$APP_ID" <<'PYVERIFY' || return 1
import pathlib, plistlib, subprocess, sys
app, widget, group = sys.argv[1:]
for path in (app, widget):
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", path],
                            check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout)
    if group not in entitlements.get("com.apple.security.application-groups", []):
        raise SystemExit("应用与小组件必须保留原 App Group")
    if path == widget and entitlements.get("com.apple.security.app-sandbox") is not True:
        raise SystemExit("小组件缺少 App Sandbox 权限")
with (pathlib.Path(widget) / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
if "MacOSX" not in info.get("CFBundleSupportedPlatforms", []):
    raise SystemExit("小组件缺少 Xcode 生成的 macOS 平台元数据")
PYVERIFY
    widget_exec=$(plist_value "$widget" CFBundleExecutable)
    [[ "$widget_exec" == ResearchWidgets ]] || { fail '小组件可执行文件不正确'; return 1; }
    # A PlugInKit record alone does not establish that WidgetKit can launch it.
    xcrun nm -u "$widget/Contents/MacOS/$widget_exec" | grep '_NSExtensionMain$' >/dev/null || { fail '小组件缺少 NSExtensionMain 入口'; return 1; }
}
verify_bundle "$SOURCE" || exit $?
[[ "$SOURCE" != "$TARGET" ]] || { fail '不能将当前已安装应用作为替换源'; exit 1; }
if pgrep -f '^/Applications/搞研究.app/Contents/MacOS/AcademicAchievementManager' >/dev/null; then
    fail '请先退出当前应用'; exit 1
fi
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    [[ -d "$TARGET" && ! -L "$TARGET" && "$(plist_value "$TARGET" CFBundleIdentifier)" == "$APP_ID" ]] || { fail '安装位置已有其他应用或符号链接，停止替换'; exit 1; }
fi

# Remove only missing hosts with this exact bundle identifier. A stale higher
# version of the integrated app can otherwise supersede the standalone widget.
STAGE=${STAGE:-$(mktemp -d "$ROOT/.install.noindex.XXXXXXXX")}
"$LSREGISTER" -dump > "$STAGE/launchservices.txt"
python3 "$ROOT/scripts/registered_apps.py" "$STAGE/launchservices.txt" "$APP_ID" > "$STAGE/stale-hosts.bin"
while IFS= read -r -d '' old_host; do
    print -- "移除已不存在的旧宿主登记：$old_host"
    "$LSREGISTER" -u "$old_host"
    pluginkit -r "$old_host/Contents/PlugIns/ResearchWidgets.appex" >/dev/null 2>&1 || true
done < "$STAGE/stale-hosts.bin"

if ! ELECTIONS=$(pluginkit -m -A -D -i "$WIDGET_ID" 2> "$STAGE/election-error.txt"); then
    # A first install can have no matches. A daemon error is not an empty result.
    if [[ -s "$STAGE/election-error.txt" ]]; then
        cat "$STAGE/election-error.txt" >&2
        fail '无法读取现有小组件登记，停止替换'; exit 1
    fi
fi
if [[ "$ELECTIONS" == *$'\n-'* || "$ELECTIONS" == -* ]]; then
    OLD_ELECTION=ignore
elif [[ "$ELECTIONS" == *$'\n+'* || "$ELECTIONS" == +* ]]; then
    OLD_ELECTION=use
fi
SAFETY="$ROOT/rollback/搞研究-$(date +%Y%m%d-%H%M%S)-$$.app"
mkdir -p "$ROOT/rollback"
TRANSACTION_STARTED=1
if [[ -d "$TARGET" ]]; then
    if [[ -d "$NEW_WIDGET" ]]; then
        if ! pluginkit -r "$NEW_WIDGET" 2> "$STAGE/old-remove-error.txt"; then
            if [[ "$(<"$STAGE/old-remove-error.txt")" != "remove: no plugin at $NEW_WIDGET" ]]; then
                cat "$STAGE/old-remove-error.txt" >&2
                fail '无法注销旧小组件登记'; exit 1
            fi
        fi
    fi
    "$LSREGISTER" -u "$TARGET"
    /bin/mv "$TARGET" "$SAFETY"
    OLD_MOVED=1
fi
TARGET_WRITTEN=1
ditto "$SOURCE" "$TARGET"
verify_bundle "$TARGET" || exit $?
register_new_widget() {
    "$LSREGISTER" -f -R "$TARGET" || return 1
    pluginkit -a "$NEW_WIDGET" || return 1
    pluginkit -e use -i "$WIDGET_ID" || return 1
}
register_new_widget || exit $?
wait_for_registration() {
    local attempt registration matched stable_matches=0
    # LaunchServices/PlugInKit ingest asynchronously after replacing a bundle.
    # Wait for this exact path AND release, rather than accepting the old entry.
    for attempt in {1..30}; do
        matched=0
        if registration=$(pluginkit -m -A -D -vv -i "$WIDGET_ID"); then
            if print -r -- "$registration" | awk -v expected_header="$WIDGET_ID($VERSION)" -v expected_path="$NEW_WIDGET" '
                $1 == "+" { candidate = ($2 == expected_header); next }
                $1 == "-" || $1 == "=" { candidate = 0; next }
                $1 == "Path" && $2 == "=" {
                    path = $0
                    sub(/^[[:space:]]*Path = /, "", path)
                    if (candidate && path == expected_path) found = 1
                    candidate = 0
                }
                END { exit !found }
            '; then
                matched=1
            fi
        fi
        if (( matched )); then
            (( stable_matches += 1 ))
            # A late old-host removal can erase a briefly visible new entry.
            # Require ten consecutive samples before committing the install.
            if (( stable_matches >= 10 )); then return 0; fi
        else
            if (( stable_matches > 0 || attempt == 3 || attempt == 8 )); then
                # Reconcile only this host/extension after delayed removal.
                register_new_widget || return 1
            fi
            stable_matches=0
        fi
        /bin/sleep 1
    done
    return 1
}
wait_for_registration || { fail '等待后仍未找到已启用的新版本小组件登记'; exit 1; }
COMMITTED=1
# Let WidgetKit discover the new extension version through the exact PlugInKit
# registration. Do not restart shared widget/Notification Center processes.
print -- "已安装 $TARGET（V$VERSION，构建 $NUMBER）；小组件入口、签名和登记检查通过。"
print -- '系统小组件的实际显示需在用户桌面确认；本安装过程未启动应用或执行冒烟测试。'
if (( OLD_MOVED )); then print -- "旧程序恢复副本：$SAFETY"; fi
