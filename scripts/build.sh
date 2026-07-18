#!/usr/bin/env bash
# Build ClutterCatcher for the iOS Simulator.
# Honors DEVELOPER_DIR (D4): export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
# to build with the Xcode 27 beta toolchain; unset for stable Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${SIM_NAME:-iPhone 17}"
SIM_OS="${SIM_OS:-26.5}"

xcodegen generate

xcodebuild \
  -project ClutterCatcher.xcodeproj \
  -scheme ClutterCatcher \
  -destination "platform=iOS Simulator,name=${SIM_NAME},OS=${SIM_OS}" \
  build
