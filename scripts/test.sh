#!/usr/bin/env bash
# Run the ClutterCatcher test suite on the iOS Simulator.
# Honors DEVELOPER_DIR (D4) — see scripts/build.sh.
# SIM_NAME/SIM_OS select the destination (M6.2): run the suite on the iPad
# family with SIM_NAME="iPad Pro 11-inch (M5)" scripts/test.sh (DL14's OS).
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${SIM_NAME:-iPhone 17}"
SIM_OS="${SIM_OS:-26.5}"

xcodegen generate

xcodebuild \
  -project ClutterCatcher.xcodeproj \
  -scheme ClutterCatcher \
  -destination "platform=iOS Simulator,name=${SIM_NAME},OS=${SIM_OS}" \
  test
