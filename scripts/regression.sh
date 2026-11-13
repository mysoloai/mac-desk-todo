#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> build app bundle"
bash scripts/build.sh

echo "==> self check (logic + interaction)"
build/DeskTodo.app/Contents/MacOS/DeskTodo --selfcheck

echo "==> snapshot render"
rm -rf build/snapshot
build/DeskTodo.app/Contents/MacOS/DeskTodo --snapshot build/snapshot >/dev/null
test -s build/snapshot/panel.png
test -s build/snapshot/settings.png

echo "==> git diff check"
if [ "$(git rev-parse --show-toplevel 2>/dev/null || true)" = "$(pwd -P)" ]; then
  git diff --check
else
  echo "==> 当前项目未初始化 Git：跳过差异检查，托管状态需如实记录"
fi

echo "==> regression passed"
