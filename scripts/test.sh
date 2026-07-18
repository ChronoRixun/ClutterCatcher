#!/usr/bin/env bash
# Run the ClutterCatcher test suite on the iOS Simulator.
# Honors DEVELOPER_DIR (D4) — see scripts/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${SIM_NAME:-iPhone 17}"

xcodegen generate

xcodebuild \
  -project ClutterCatcher.xcodeproj \
  -scheme ClutterCatcher \
  -destination "platform=iOS Simulator,name=${SIM_NAME}" \
  test
