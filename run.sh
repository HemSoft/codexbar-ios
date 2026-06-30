#!/usr/bin/env bash
set -euo pipefail

PROJECT="CodexBarIOS.xcodeproj"
SCHEME="CodexBarIOS"
BUNDLE_ID="com.hemsoft.CodexBarIOS"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$(dirname "$0")"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory not found: $DEVELOPER_DIR" >&2
  exit 1
fi

export DEVELOPER_DIR

DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17,OS=26.5}"

echo "Building $SCHEME for $DESTINATION"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  -quiet \
  build

BUILD_DIR="$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  -showBuildSettings \
  2>/dev/null | awk -F'= ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')"

APP_PATH="$BUILD_DIR/$SCHEME.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found: $APP_PATH" >&2
  exit 1
fi

DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone 17 / && /Shutdown|Booted/ {print $2; exit}')"

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Shutdown|Booted/ {print $2; exit}')"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "No available iPhone simulator found." >&2
  exit 1
fi

echo "Booting simulator $DEVICE_ID"
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null

echo "Installing $APP_PATH"
xcrun simctl install "$DEVICE_ID" "$APP_PATH"

echo "Launching $BUNDLE_ID"
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"

open -a Simulator

