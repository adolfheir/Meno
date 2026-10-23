#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for script in scripts/*.sh; do bash -n "$script"; done
python3 scripts/check-source.py
plutil -lint apps/Meno/Info.plist
git diff --check
git diff --cached --check
