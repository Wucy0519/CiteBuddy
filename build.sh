#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"
BUILD="$ROOT/build"
APP="$ROOT/../引用工作台.app"

killall "引用工作台" 2>/dev/null || true

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD/icon.iconset" "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -sdk "$SDK" -target "$TARGET" -O -framework AppKit \
  -o "$BUILD/MakeIcon" "$ROOT/Tools/MakeIcon.swift"
"$BUILD/MakeIcon" "$BUILD/icon-1024.png"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$BUILD/icon-1024.png" --out "$BUILD/icon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$BUILD/icon-1024.png" --out "$BUILD/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

swiftc -sdk "$SDK" -target "$TARGET" -O -whole-module-optimization \
  -framework AppKit -framework CryptoKit \
  -o "$APP/Contents/MacOS/引用工作台" \
  "$ROOT/Sources/BibTex.swift" \
  "$ROOT/Sources/DBLP.swift" \
  "$ROOT/Sources/Check.swift" \
  "$ROOT/Sources/WorkbenchUI.swift" \
  "$ROOT/Sources/AppMain.swift"

cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/testdata/sample.bib" "$APP/Contents/Resources/sample.bib"
cp "$ROOT/testdata/titles.txt" "$APP/Contents/Resources/titles.txt"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/引用工作台" --self-test
echo "已生成 $APP"
