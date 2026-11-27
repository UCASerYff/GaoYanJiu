#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Darwin ]]; then
    echo 'This test needs the macOS Swift SDK.' >&2
    exit 1
fi
if [[ -z ${GAO_CAOZUO_SOURCE:-} ]]; then
    echo 'Set GAO_CAOZUO_SOURCE to a GaoCaoZuo source checkout containing ScreenshotOCRReturn.swift.' >&2
    exit 2
fi
PROVIDER=$(cd "$GAO_CAOZUO_SOURCE" && pwd)
WORK=$(mktemp -d /private/tmp/gao-research-ocr-interop.XXXXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SDK=$(xcrun --sdk macosx --show-sdk-path)
SWIFT=(xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -Onone -sdk "$SDK"
       -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$WORK/cache"
       -framework AppKit -framework CryptoKit -framework Security -framework UniformTypeIdentifiers)
FIXTURE="$ROOT/Tests/ResearchOCRReturnInterop.swift"

"${SWIFT[@]}" "$ROOT/Sources/GaoActionV1.swift" "$ROOT/Sources/ResearchExchangeClients.swift" \
    "$ROOT/Sources/ResearchOCRReturns.swift" "$FIXTURE" -o "$WORK/research"
"${SWIFT[@]}" -D OCR_RETURN_PROVIDER_FIXTURE -framework ImageIO \
    "$PROVIDER/Sources/ScreenshotGaoActionModel.swift" "$PROVIDER/Sources/ScreenshotGaoActionTransport.swift" \
    "$PROVIDER/Sources/ScreenshotGaoActionState.swift" "$PROVIDER/Sources/ScreenshotOCRReturn.swift" \
    "$PROVIDER/Sources/ScreenshotCore.swift" "$PROVIDER/Sources/ScreenshotMigration.swift" \
    "$PROVIDER/Sources/ScreenshotMigrationActivity.swift" "$PROVIDER/Sources/ScreenshotMigrationActivityReader.swift" \
    "$PROVIDER/Sources/ScreenshotMigrationHistoryPolicy.swift" \
    "$PROVIDER/Sources/ScreenshotMigrationIO.swift" "$PROVIDER/Sources/ScreenshotMigrationValidation.swift" \
    "$FIXTURE" -o "$WORK/provider"

REQUEST=$("$WORK/research" "$WORK" prepare)
"$WORK/provider" "$WORK" publish "$REQUEST"
"$WORK/research" "$WORK" receive "$REQUEST"
