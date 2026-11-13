#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="DeskTodo"
BUNDLE="build/${APP_NAME}.app"
STAGE="build/.stage-${APP_NAME}.app"
ARCH="$(uname -m)"

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

echo "==> compile (${ARCH})"
# shellcheck disable=SC2046
swiftc -O -whole-module-optimization \
  -target "${ARCH}-apple-macosx12.0" \
  $(find src -name '*.swift' | sort) \
  -o "$STAGE/Contents/MacOS/${APP_NAME}" \
  -framework AppKit -framework Carbon

cp Resources/Info.plist "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# Dock 图标（bash scripts/make-icon.sh 生成；缺失时退回系统占位图标）
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
else
  echo "==> warn: 缺少 Resources/AppIcon.icns，Dock 图标会是系统占位图标"
fi

if codesign --force --sign - "$STAGE" >/dev/null 2>&1; then
  echo "==> ad-hoc signed"
else
  echo "==> warn: ad-hoc 签名失败，本地运行不受影响"
fi

# 整包替换：避免对运行中的旧包做原地覆盖（会导致 taskgated 签名缓存失配）
rm -rf "$BUNDLE"
mv "$STAGE" "$BUNDLE"

echo "built: ${BUNDLE}"
