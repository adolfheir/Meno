#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check.sh
swift test --package-path packages/MenoControlProtocol
swift test --package-path packages/MenoPluginKit
swift test --package-path packages/MenoCLIKit
swift test --package-path plugins/Reminders
swift build
