#!/usr/bin/env bash
# Simulator smoke walkthrough for M1 VERIFY:
# builds, installs, launches, injects a QR deep link for a seeded container's
# child (create one first in-app or pass CONTAINER_UUID), and captures a screenshot.
#
# Usage:
#   scripts/ui-smoke.sh                      # launch + screenshot home
#   CONTAINER_UUID=<uuid> scripts/ui-smoke.sh  # also exercise the deep link
#
# Honors DEVELOPER_DIR (D4). Screenshots land in artifacts/.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${SIM_NAME:-iPhone 17}"
SIM_OS="${SIM_OS:-26.5}"
BUNDLE_ID="com.rixun.cluttercatcher"
mkdir -p artifacts

xcodegen generate
xcodebuild \
  -project ClutterCatcher.xcodeproj \
  -scheme ClutterCatcher \
  -destination "platform=iOS Simulator,name=${SIM_NAME},OS=${SIM_OS}" \
  -derivedDataPath build/DerivedData \
  build

APP_PATH="build/DerivedData/Build/Products/Debug-iphonesimulator/ClutterCatcher.app"

xcrun simctl boot "${SIM_NAME}" 2>/dev/null || true
open -a Simulator || true
xcrun simctl bootstatus "${SIM_NAME}" -b
xcrun simctl install "${SIM_NAME}" "${APP_PATH}"
xcrun simctl launch "${SIM_NAME}" "${BUNDLE_ID}"
sleep 3
xcrun simctl io "${SIM_NAME}" screenshot artifacts/01-rooms-home.png

if [[ -n "${CONTAINER_UUID:-}" ]]; then
  xcrun simctl openurl "${SIM_NAME}" "cluttercatcher://c/${CONTAINER_UUID}"
  sleep 2
  xcrun simctl io "${SIM_NAME}" screenshot artifacts/02-deeplink-container.png
  echo "Deep link screenshot: artifacts/02-deeplink-container.png"
fi

echo "Smoke walkthrough artifacts in artifacts/"
