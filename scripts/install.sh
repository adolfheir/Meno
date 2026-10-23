#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$HOME/Applications}"
if [[ ! -d dist/Meno.app ]]; then echo "请先运行 scripts/build.sh。" >&2; exit 2; fi
mkdir -p "$destination"
if [[ -e "$destination/Meno.app" ]]; then
  if pgrep -f "^$destination/Meno.app/Contents/MacOS/Meno" >/dev/null; then echo "请先正常退出已安装的 Meno。" >&2; exit 2; fi
  mv "$destination/Meno.app" "$destination/Meno.previous.$(date +%Y%m%d-%H%M%S).app"
fi
ditto dist/Meno.app "$destination/Meno.app"
codesign --verify --deep --strict "$destination/Meno.app"
echo "已安装：$destination/Meno.app"
