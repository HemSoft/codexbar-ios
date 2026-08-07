#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "$script_dir/../.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

cat > "$temporary_dir/simulators.json" <<'JSON'
{
  "runtimes": [
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-4",
      "version": "26.4",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-5",
      "version": "26.5",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0",
      "version": "27.0",
      "isAvailable": true
    }
  ],
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.watchOS-26-4": [
      {
        "name": "Apple Watch Alpha",
        "udid": "OLDER-COMPATIBLE",
        "isAvailable": true
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-26-5": [
      {
        "name": "Apple Watch Zulu",
        "udid": "NEWEST-COMPATIBLE-ZULU",
        "isAvailable": true
      },
      {
        "name": "Apple Watch Alpha",
        "udid": "NEWEST-COMPATIBLE-ALPHA",
        "isAvailable": true
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [
      {
        "name": "Apple Watch Alpha",
        "udid": "NEWER-INCOMPATIBLE",
        "isAvailable": true
      }
    ]
  }
}
JSON

selected_device="$(
  WATCH_SIMULATOR_SDK_VERSION=26.5 \
  WATCH_SIMULATOR_LIST_JSON_FILE="$temporary_dir/simulators.json" \
    "$repository_dir/scripts/select-watch-simulator.sh" 2> "$temporary_dir/selection.log"
)"

if [[ "$selected_device" != "NEWEST-COMPATIBLE-ALPHA" ]]; then
  echo "Expected deterministic compatible device, got: $selected_device" >&2
  exit 1
fi

if ! grep -q "watchOS 26.5" "$temporary_dir/selection.log"; then
  echo "Expected the selection diagnostic to identify watchOS 26.5." >&2
  exit 1
fi

preferred_device="$({
  WATCH_SIMULATOR_SDK_VERSION=26.5 \
  WATCH_SIMULATOR_DEVICE_NAME="Apple Watch Zulu" \
  WATCH_SIMULATOR_LIST_JSON_FILE="$temporary_dir/simulators.json" \
    "$repository_dir/scripts/select-watch-simulator.sh"
} 2> "$temporary_dir/preferred-selection.log")"

if [[ "$preferred_device" != "NEWEST-COMPATIBLE-ZULU" ]]; then
  echo "Expected preferred compatible device, got: $preferred_device" >&2
  exit 1
fi

cat > "$temporary_dir/no-compatible-simulators.json" <<'JSON'
{
  "runtimes": [
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0",
      "version": "27.0",
      "isAvailable": true
    }
  ],
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [
      {
        "name": "Apple Watch Alpha",
        "udid": "NEWER-INCOMPATIBLE",
        "isAvailable": true
      }
    ]
  }
}
JSON

cat > "$temporary_dir/xcrun" <<'SH'
#!/usr/bin/env bash
if [[ -n "${EXPECTED_DEVELOPER_DIR:-}" && "${DEVELOPER_DIR:-}" != "$EXPECTED_DEVELOPER_DIR" ]]; then
  printf 'Expected DEVELOPER_DIR %s, got %s\n' "$EXPECTED_DEVELOPER_DIR" "${DEVELOPER_DIR:-unset}" >&2
  exit 1
fi
case "$*" in
  *"--sdk watchsimulator --show-sdk-version"*)
    printf '26.5\n'
    ;;
  *"simctl list --json"*)
    command cat "$SIMULATOR_FIXTURE_PATH"
    ;;
  *"simctl list runtimes available"*)
    printf 'mock available watchOS runtime diagnostics\n'
    ;;
  *"simctl list devices available"*)
    printf 'mock available Apple Watch device diagnostics\n'
    ;;
  *)
    printf 'Unexpected xcrun arguments: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$temporary_dir/xcrun"

alternate_developer_dir="$temporary_dir/AlternateXcode.app/Contents/Developer"
inherited_device="$({
  PATH="$temporary_dir:$PATH" \
  DEVELOPER_DIR="$alternate_developer_dir" \
  EXPECTED_DEVELOPER_DIR="$alternate_developer_dir" \
  SIMULATOR_FIXTURE_PATH="$temporary_dir/simulators.json" \
    "$repository_dir/scripts/select-watch-simulator.sh"
} 2> "$temporary_dir/inherited-selection.log")"

if [[ "$inherited_device" != "NEWEST-COMPATIBLE-ALPHA" ]]; then
  echo "Expected selection to preserve the caller's Xcode, got: $inherited_device" >&2
  exit 1
fi

if PATH="$temporary_dir:$PATH" \
  WATCH_SIMULATOR_SDK_VERSION=26.5 \
  WATCH_SIMULATOR_LIST_JSON_FILE="$temporary_dir/no-compatible-simulators.json" \
    "$repository_dir/scripts/select-watch-simulator.sh" \
    > "$temporary_dir/no-compatible.stdout" \
    2> "$temporary_dir/no-compatible.stderr"; then
  echo "Expected selection to fail when only a newer runtime is installed." >&2
  exit 1
fi

if ! grep -q "Active watchsimulator SDK: 26.5" "$temporary_dir/no-compatible.stderr"; then
  echo "Expected failure diagnostics to identify the active SDK." >&2
  exit 1
fi

if ! grep -q "mock available watchOS runtime diagnostics" \
  "$temporary_dir/no-compatible.stderr"; then
  echo "Expected failure diagnostics to list available runtimes." >&2
  exit 1
fi

if ! grep -q "mock available Apple Watch device diagnostics" \
  "$temporary_dir/no-compatible.stderr"; then
  echo "Expected failure diagnostics to list available devices." >&2
  exit 1
fi

echo "Watch simulator selector tests passed."
