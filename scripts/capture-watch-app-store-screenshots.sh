#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/AppStoreWatchScreenshots"
OUTPUT_DIR="$ROOT_DIR/release-assets/1.2/screenshots"
APP_BUNDLE_ID="com.hemsoft.CodexBarIOS.watchkitapp"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-watchsimulator/CodexBarWatch.app"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCREENSHOT_SETTLE_SECONDS="${SCREENSHOT_SETTLE_SECONDS:-3}"
READY_FILE_NAME="app-store-watch-screenshot-ready"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-60}"
WATCH_DEVICE_NAME="${WATCH_DEVICE_NAME:-}"

export DEVELOPER_DIR

if ! command -v sips >/dev/null 2>&1; then
  echo "The macOS sips utility is required to flatten screenshots." >&2
  exit 1
fi

SCENES=(
  "overview:13-watch-dashboard-overview.png"
  "balances:14-watch-dashboard-balances.png"
)

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-watch-screenshots.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

watch_device_id="$(
  WATCH_SIMULATOR_DEVICE_NAME="$WATCH_DEVICE_NAME" \
    "$ROOT_DIR/scripts/select-watch-simulator.sh"
)"

echo "Building CodexBarWatch for $watch_device_id..."
xcodebuild \
  -project "$ROOT_DIR/CodexBarIOS.xcodeproj" \
  -scheme CodexBarWatch \
  -configuration Debug \
  -destination "platform=watchOS Simulator,id=$watch_device_id" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  build

echo "Booting the isolated Apple Watch simulator..."
xcrun simctl boot "$watch_device_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$watch_device_id" -b
xcrun simctl terminate "$watch_device_id" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$watch_device_id" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$watch_device_id" "$APP_PATH"
data_container="$(xcrun simctl get_app_container "$watch_device_id" "$APP_BUNDLE_ID" data)"
ready_file="$data_container/Library/Caches/$READY_FILE_NAME"

mkdir -p "$OUTPUT_DIR"

wait_for_scene_ready() {
  local scene="$1"
  local deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
  local ready_scene=""

  while (( SECONDS < deadline )); do
    ready_scene="$(cat "$ready_file" 2>/dev/null || true)"
    if [[ "$ready_scene" == "$scene" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "Timed out waiting for Watch scene '$scene'. Last value: '${ready_scene:-<unset>}'" >&2
  return 1
}

verify_dimensions() {
  local image_path="$1"
  local dimensions
  local has_alpha

  dimensions="$(
    sips -g pixelWidth -g pixelHeight "$image_path" 2>/dev/null \
      | awk '/pixelWidth/ { width = $2 } /pixelHeight/ { height = $2 } END { print width "x" height }'
  )"
  has_alpha="$(sips -g hasAlpha "$image_path" 2>/dev/null | awk '/hasAlpha/ { print $2 }')"

  if [[ "$has_alpha" != "no" ]]; then
    echo "Expected an opaque storefront PNG, but $image_path hasAlpha is $has_alpha." >&2
    return 1
  fi

  case "$dimensions" in
    422x514|410x502|416x496|396x484|368x448|312x390)
      echo "Verified $(basename "$image_path") at accepted Apple Watch size $dimensions"
      ;;
    *)
      echo "Unexpected Apple Watch screenshot dimensions for $image_path: $dimensions" >&2
      return 1
      ;;
  esac
}

for scene_entry in "${SCENES[@]}"; do
  IFS=":" read -r scene filename <<< "$scene_entry"
  raw_path="$temporary_directory/$filename"
  opaque_path="$temporary_directory/${filename%.png}.bmp"
  output_path="$OUTPUT_DIR/$filename"

  echo "Capturing privacy-safe Watch scene: $scene"
  xcrun simctl terminate "$watch_device_id" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  rm -f "$ready_file"
  xcrun simctl launch --terminate-running-process "$watch_device_id" "$APP_BUNDLE_ID" \
    --app-store-screenshots \
    --app-store-watch-scene "$scene" \
    --app-store-settle-seconds "$SCREENSHOT_SETTLE_SECONDS" >/dev/null
  wait_for_scene_ready "$scene"
  xcrun simctl io "$watch_device_id" screenshot --type=png "$raw_path"
  sips -s format bmp "$raw_path" --out "$opaque_path" >/dev/null
  sips -s format png "$opaque_path" --out "$output_path" >/dev/null
  verify_dimensions "$output_path"
done

echo "Sanitized Apple Watch screenshots are in $OUTPUT_DIR"
