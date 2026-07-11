#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/AppStoreScreenshots"
OUTPUT_DIR="$ROOT_DIR/AppStore/Screenshots"
FASTLANE_OUTPUT_DIR="$ROOT_DIR/fastlane/screenshots/en-US"
APP_BUNDLE_ID="com.hemsoft.CodexBarIOS"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/CodexBarIOS.app"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
READY_FILE_NAME="app-store-screenshot-ready"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-60}"

export DEVELOPER_DIR

PHONE_DEVICE="${PHONE_DEVICE:-iPhone 17 Pro Max}"
IPAD_DEVICE="${IPAD_DEVICE:-iPad Pro 13-inch (M5)}"

SCENES=(
  "dashboard-overview:light"
  "dashboard-dark:dark"
  "widget-builder:light"
  "accounts:dark"
  "provider-copilot:light"
  "history:dark"
)

mkdir -p "$OUTPUT_DIR" "$FASTLANE_OUTPUT_DIR"

echo "Removing stale generated screenshots..."
rm -f "$OUTPUT_DIR"/*.png "$FASTLANE_OUTPUT_DIR"/*.png

echo "Building CodexBarIOS for Simulator..."
xcodebuild \
  -project "$ROOT_DIR/CodexBarIOS.xcodeproj" \
  -scheme CodexBarIOS \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$PHONE_DEVICE" \
  -derivedDataPath "$DERIVED_DATA" \
  build

simulator_udid() {
  local device_name="$1"
  xcrun simctl list devices available | { grep -F "$device_name" || true; } | head -n 1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/'
}

boot_device() {
  local device_name="$1"
  local booted_device="$2"

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
}

wait_for_scene_ready() {
  local ready_file="$1"
  local scene="$2"
  local deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
  local ready_scene=""

  while (( SECONDS < deadline )); do
    ready_scene="$(cat "$ready_file" 2>/dev/null || true)"
    if [[ "$ready_scene" == "$scene" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "Timed out waiting for $ready_file to equal '$scene'. Last value: '${ready_scene:-<unset>}'" >&2
  return 1
}

verify_dimensions() {
  local image_path="$1"
  local expected_width="$2"
  local expected_height="$3"
  local actual_width
  local actual_height

  actual_width="$(sips -g pixelWidth "$image_path" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
  actual_height="$(sips -g pixelHeight "$image_path" 2>/dev/null | awk '/pixelHeight/ {print $2}')"

  if [[ "$actual_width" != "$expected_width" || "$actual_height" != "$expected_height" ]]; then
    echo "Unexpected dimensions for $image_path: ${actual_width}x${actual_height}, expected ${expected_width}x${expected_height}" >&2
    return 1
  fi

  echo "Verified $(basename "$image_path") at ${actual_width}x${actual_height}"
}

capture_scene() {
  local booted_device="$1"
  local family="$2"
  local scene="$3"
  local appearance="$4"
  local expected_width="$5"
  local expected_height="$6"
  local output_path="$OUTPUT_DIR/${family}_${scene}_${appearance}.png"
  local data_container
  local ready_file

  echo "Capturing $family / $scene / $appearance..."
  xcrun simctl terminate "$booted_device" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$booted_device" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$booted_device" "$APP_PATH"
  data_container="$(xcrun simctl get_app_container "$booted_device" "$APP_BUNDLE_ID" data)"
  ready_file="$data_container/Library/Caches/$READY_FILE_NAME"
  rm -f "$ready_file"
  xcrun simctl launch --terminate-running-process "$booted_device" "$APP_BUNDLE_ID" \
    --app-store-screenshots \
    --app-store-scene "$scene" \
    --app-store-appearance "$appearance" >/dev/null

  wait_for_scene_ready "$ready_file" "$scene"
  xcrun simctl io "$booted_device" screenshot --type=png "$output_path"
  verify_dimensions "$output_path" "$expected_width" "$expected_height"
}

capture_for_device() {
  local device_name="$1"
  local family="$2"
  local expected_width="$3"
  local expected_height="$4"
  local booted_device
  local scene_entry
  local scene
  local appearance

  booted_device="$(simulator_udid "$device_name")"
  if [[ -z "$booted_device" ]]; then
    echo "Could not find simulator: $device_name" >&2
    return 1
  fi

  boot_device "$device_name" "$booted_device"

  for scene_entry in "${SCENES[@]}"; do
    IFS=":" read -r scene appearance <<< "$scene_entry"
    capture_scene "$booted_device" "$family" "$scene" "$appearance" "$expected_width" "$expected_height"
  done
}

mirror_fastlane_screenshots() {
  local number=1
  local scene_entry
  local scene
  local appearance
  local padded
  local source_path

  for scene_entry in "${SCENES[@]}"; do
    IFS=":" read -r scene appearance <<< "$scene_entry"
    padded="$(printf "%02d" "$number")"

    source_path="$OUTPUT_DIR/iphone-17-pro-max_${scene}_${appearance}.png"
    cp "$source_path" "$FASTLANE_OUTPUT_DIR/${padded}_iphone_6_9_${scene}_${appearance}.png"

    source_path="$OUTPUT_DIR/ipad-pro-13-m5_${scene}_${appearance}.png"
    cp "$source_path" "$FASTLANE_OUTPUT_DIR/${padded}_ipad_13_${scene}_${appearance}.png"

    number=$((number + 1))
  done
}

capture_for_device "$PHONE_DEVICE" "iphone-17-pro-max" "1320" "2868"
capture_for_device "$IPAD_DEVICE" "ipad-pro-13-m5" "2064" "2752"
mirror_fastlane_screenshots

echo "Screenshots are in $OUTPUT_DIR and mirrored to $FASTLANE_OUTPUT_DIR"
