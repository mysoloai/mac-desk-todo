#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="build/AppIcon-1024.png"
ICONSET="build/AppIcon.iconset"

mkdir -p build
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> 生成图标源图"
swift scripts/make-icon.swift "$SOURCE"

echo "==> 生成 iconset"
sips -z 16 16 "$SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$SOURCE" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "built: Resources/AppIcon.icns"
