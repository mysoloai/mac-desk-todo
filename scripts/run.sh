#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# 先退出旧实例，再做整包替换并启动
pkill -x DeskTodo 2>/dev/null || true
sleep 0.4

bash scripts/build.sh
open "build/DeskTodo.app"
echo "==> launched build/DeskTodo.app"
