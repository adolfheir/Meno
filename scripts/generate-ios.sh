#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --spec apps/MenoIOS/project.yml
if [[ -f MenoSync.json ]]; then
  python3 scripts/configure-sync-plist.py apps/MenoIOS/Info.plist MenoSync.json
fi
