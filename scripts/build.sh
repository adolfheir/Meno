#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  echo "用法：scripts/build.sh [release|debug]" >&2
  exit 2
fi
root="$(pwd)"
target="$root/dist/Meno.app"
# A normal quit returns its acknowledgement before AppKit has finished stopping.
for attempt in {1..50}; do
  if ! pgrep -f "^$target/Contents/MacOS/Meno" >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -f "^$target/Contents/MacOS/Meno" >/dev/null; then
  echo "请先用 dist/Meno.app/Contents/Helpers/meno quit 正常退出，再替换应用。" >&2
  exit 2
fi
swift build --configuration "$configuration"
bin="$(swift build --configuration "$configuration" --show-bin-path)"
mkdir -p dist
stage="$(mktemp -d "$root/dist/.build-app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Meno.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp apps/Meno/Info.plist "$app/Contents/Info.plist"
cp "$bin/MenoHost" "$app/Contents/MacOS/Meno"
cp "$bin/meno" "$app/Contents/Helpers/meno"
cp "$bin/meno-mcp" "$app/Contents/Helpers/meno-mcp"
chmod 755 "$app/Contents/MacOS/Meno" "$app/Contents/Helpers/meno" "$app/Contents/Helpers/meno-mcp"
swift scripts/make-icon.swift "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles use Bundle.main.resourceURL for embedded applications.
for resource in "$bin"/*.bundle; do
  if [[ -d "$resource" ]]; then cp -R "$resource" "$app/Contents/Resources/"; fi
done
mkdir -p "$app/Contents/Resources/Licenses"
for checkout in .build/checkouts/*; do
  name="$(basename "$checkout")"
  for license in "$checkout"/LICENSE "$checkout"/LICENSE.txt "$checkout"/LICENSE.md "$checkout"/NOTICE "$checkout"/NOTICE.txt; do
    if [[ -f "$license" ]]; then cp "$license" "$app/Contents/Resources/Licenses/$name-$(basename "$license")"; fi
  done
done
identity="${MENO_SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$identity" "$app/Contents/Helpers/meno"
codesign --force --options runtime --timestamp=none --sign "$identity" "$app/Contents/Helpers/meno-mcp"
codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
python3 scripts/build-info.py "$app" "$configuration" "$stage/build-info.json"
python3 scripts/verify-app.py "$app" --manifest "$stage/build-info.json"
if [[ -d "$target" ]]; then mv "$target" "$root/dist/Meno.previous.$(date +%Y%m%d-%H%M%S).app"; fi
mv "$app" "$target"
mv "$stage/build-info.json" "$root/dist/build-info.json"
ditto -c -k --sequesterRsrc --keepParent "$target" "$root/dist/Meno.zip"
(cd "$root/dist" && shasum -a 256 Meno.zip build-info.json > SHA256SUMS)
echo "已生成：$target"
echo "双击打开或运行：open '$target'"
