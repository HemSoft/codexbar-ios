#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/AppStoreScreenshots"
OUTPUT_DIR="$ROOT_DIR/AppStore/Screenshots"
APP_BUNDLE_ID="com.hemsoft.CodexBarIOS"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/CodexBarIOS.app"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

export DEVELOPER_DIR

PHONE_DEVICE="${PHONE_DEVICE:-iPhone 17 Pro Max}"
IPAD_DEVICE="${IPAD_DEVICE:-iPad Pro 13-inch (M5)}"

mkdir -p "$OUTPUT_DIR"

echo "Building CodexBarIOS for Simulator..."
xcodebuild \
  -project "$ROOT_DIR/CodexBarIOS.xcodeproj" \
  -scheme CodexBarIOS \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$PHONE_DEVICE" \
  -derivedDataPath "$DERIVED_DATA" \
  build

capture_for_device() {
  local device_name="$1"
  local output_name="$2"
  local booted_device

  booted_device="$(xcrun simctl list devices available | grep -F "$device_name" | head -n 1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')"
  if [[ -z "$booted_device" ]]; then
    echo "Could not find simulator: $device_name" >&2
    return 1
  fi

  echo "Booting $device_name ($booted_device)..."
  xcrun simctl boot "$booted_device" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$booted_device" -b

  xcrun simctl status_bar "$booted_device" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiBars 3 \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100 >/dev/null 2>&1 || true

  xcrun simctl uninstall "$booted_device" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$booted_device" "$APP_PATH"
  xcrun simctl launch --terminate-running-process "$booted_device" "$APP_BUNDLE_ID" --app-store-screenshots

  sleep 10

  local output_path="$OUTPUT_DIR/$output_name"
  xcrun simctl io "$booted_device" screenshot --type=png "$output_path"
  echo "Saved $output_path"
}

capture_for_device "$PHONE_DEVICE" "iphone-17-pro-max-dashboard.png"
capture_for_device "$IPAD_DEVICE" "ipad-pro-13-dashboard.png"

echo "Screenshots are in $OUTPUT_DIR"
