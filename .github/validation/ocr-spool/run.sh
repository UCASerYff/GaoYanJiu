#!/bin/bash
set -euo pipefail
umask 077

if [[ "$#" != 3 ]]; then
  printf '%s\n' 'Usage: bash run.sh /checkout/GaoCaoZuo /checkout/GaoWenJian /checkout/GaoYanJiu' >&2
  exit 2
fi

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf '%s\n' 'Requires the arm64 macOS runner and the native Xcode SDK.' >&2
  exit 2
}

recipe=$(cd -- "$(dirname -- "$0")" && pwd -P)
operations=$(cd -- "$1" && pwd -P)
files=$(cd -- "$2" && pwd -P)
research=$(cd -- "$3" && pwd -P)
for checkout in "$operations" "$files" "$research"; do
  printf '%s %s\n' "${checkout##*/}" "$(git -C "$checkout" rev-parse HEAD)"
done
xcodebuild -version

work=$(mktemp -d /private/tmp/gao-ocr-spool.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fixture="$work/fixture.noindex"
mkdir -m 700 "$fixture" "$work/cache"
sdk=$(xcrun --sdk macosx --show-sdk-path)
flags=(-swift-version 5 -parse-as-library -Onone -sdk "$sdk" -target arm64-apple-macosx14.0
       -module-cache-path "$work/cache")

# Copy the exact production digest helper without pulling in capture UI or migrations.
grep -q '^struct ScreenshotCaptureAsset:' "$operations/Sources/ScreenshotCore.swift"
awk '/^struct ScreenshotCaptureAsset:/ { exit } { print }' "$operations/Sources/ScreenshotCore.swift" > "$work/ScreenshotFileSafety.swift"
grep -q '^enum ScreenshotFileSafety' "$work/ScreenshotFileSafety.swift"
grep -q '^enum ScreenshotAppIssue:' "$work/ScreenshotFileSafety.swift"
operation_sources=("$operations/Sources/ScreenshotGaoActionModel.swift" "$operations/Sources/ScreenshotGaoActionTransport.swift"
                   "$operations/Sources/ScreenshotGaoActionState.swift" "$operations/Sources/ScreenshotOCRReturn.swift"
                   "$work/ScreenshotFileSafety.swift" "$recipe/Fixture.swift" "$recipe/OperationsMain.swift")
operation_frameworks=(-framework AppKit -framework ImageIO -framework CryptoKit -framework Security)
xcrun swiftc "${flags[@]}" "${operation_sources[@]}" "${operation_frameworks[@]}" -o "$work/operations-test"

# The GUI @main remains untouched in the checkout. Only the private build copy is adjusted.
sed 's/@main @MainActor struct/@MainActor struct/' "$files/Sources/App.swift" > "$work/FilesApp.swift"
file_sources=()
for source in "$files"/Sources/*.swift; do
  [[ "${source##*/}" == App.swift ]] || file_sources+=("$source")
done
file_sources+=("$work/FilesApp.swift" "$recipe/Fixture.swift" "$recipe/FilesMain.swift")
file_frameworks=(-framework AppKit -framework SwiftUI -framework PDFKit -framework WebKit
                 -framework UniformTypeIdentifiers -framework CryptoKit -framework Security -framework CoreServices -lsqlite3)
xcrun swiftc "${flags[@]}" "${file_sources[@]}" "${file_frameworks[@]}" -o "$work/files-test"

research_sources=("$research/Sources/GaoActionV1.swift" "$research/Sources/ResearchExchangeClients.swift"
                  "$research/Sources/ResearchOCRReturns.swift" "$recipe/Fixture.swift" "$recipe/ResearchMain.swift")
research_frameworks=(-framework AppKit -framework CryptoKit -framework UniformTypeIdentifiers -framework Security)
xcrun swiftc "${flags[@]}" "${research_sources[@]}" "${research_frameworks[@]}" -o "$work/research-test"

"$work/files-test" "$fixture" prepare
"$work/research-test" "$fixture" prepare
"$work/operations-test" "$fixture" publish
"$work/files-test" "$fixture" receive
"$work/research-test" "$fixture" receive
printf '%s\n' 'PASS shared native Mac GaoAction OCR spool contract for all three checkouts.'
