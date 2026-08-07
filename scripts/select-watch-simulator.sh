#!/usr/bin/env bash

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

sdk_version="${WATCH_SIMULATOR_SDK_VERSION:-$(xcrun --sdk watchsimulator --show-sdk-version)}"
preferred_device_name="${WATCH_SIMULATOR_DEVICE_NAME:-}"

if [[ -n "${WATCH_SIMULATOR_LIST_JSON_FILE:-}" ]]; then
  simulator_json="$(<"$WATCH_SIMULATOR_LIST_JSON_FILE")"
else
  simulator_json="$(xcrun simctl list --json)"
fi

device="$({
  jq -r \
    --arg sdk_version "$sdk_version" \
    --arg preferred_device_name "$preferred_device_name" '
    def version_components:
      split(".")
      | map(tonumber)
      | (. + [0, 0, 0])[:3];

    . as $simulators
    | ($sdk_version | version_components) as $sdk
    | [
        .runtimes[]
        | select(
            .isAvailable == true
            and (.identifier | startswith("com.apple.CoreSimulator.SimRuntime.watchOS-"))
          )
        | (.version | version_components) as $runtime_version
        | select($runtime_version <= $sdk)
        | .identifier as $runtime_identifier
        | .version as $runtime_name
        | $simulators.devices[$runtime_identifier][]?
        | select(.isAvailable == true and (.name | startswith("Apple Watch")))
        | select(
            $preferred_device_name == ""
            or .name == $preferred_device_name
          )
        | {
            name,
            runtime: $runtime_name,
            runtimeVersion: $runtime_version,
            udid
          }
      ]
    | if length == 0 then
        empty
      else
        (map(.runtimeVersion) | max) as $newest_compatible_runtime
        | map(select(.runtimeVersion == $newest_compatible_runtime))
        | sort_by(.name, .udid)
        | first
        | [.udid, .name, "watchOS \(.runtime)"]
        | @tsv
      end
  ' <<< "$simulator_json"
} 2>/dev/null)"

if [[ -z "$device" ]]; then
  if [[ -n "$preferred_device_name" ]]; then
    echo "No available $preferred_device_name simulator is compatible with watchsimulator SDK $sdk_version." >&2
  else
    echo "No available Apple Watch simulator is compatible with watchsimulator SDK $sdk_version." >&2
  fi
  echo "Active watchsimulator SDK: $sdk_version" >&2
  echo "Available watchOS runtimes:" >&2
  xcrun simctl list runtimes available >&2 || true
  echo "Available Apple Watch devices:" >&2
  xcrun simctl list devices available >&2 || true
  exit 1
fi

IFS=$'\t' read -r device_id device_name runtime_name <<< "$device"
echo "Selected $device_name ($runtime_name, $device_id) for watchsimulator SDK $sdk_version." >&2
printf '%s\n' "$device_id"
