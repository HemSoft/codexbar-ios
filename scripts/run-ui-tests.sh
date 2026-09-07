#!/usr/bin/env bash

# Run both simulator families by default, or select iphone/ipad explicitly.
# Each invocation retains its xcresult, log, summary, and failure attachments.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device_family="${1:-all}"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [all|iphone|ipad]" >&2
  exit 2
fi

case "$device_family" in
  all)
    if [[ -n "${UI_TEST_DEVICE_NAME:-}" || -n "${UI_TEST_DEVICE_ID:-}" ]]; then
      echo "Pass iphone or ipad when setting a device override." >&2
      exit 2
    fi
    exit_status=0
    for family in iphone ipad; do
      "$repo_root/scripts/run-ui-tests.sh" "$family" || exit_status=1
    done
    exit "$exit_status"
    ;;
  iphone) device_prefix="iPhone" ;;
  ipad) device_prefix="iPad" ;;
  *) echo "Usage: $0 [all|iphone|ipad]" >&2; exit 2 ;;
esac

sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
simulator_json="$(xcrun simctl list --json)"
device="$(jq -r \
  --arg sdk_version "$sdk_version" \
  --arg device_prefix "$device_prefix" \
  --arg preferred_name "${UI_TEST_DEVICE_NAME:-}" \
  --arg preferred_id "${UI_TEST_DEVICE_ID:-}" '
    def version_components:
      split(".") | map(tonumber) | (. + [0, 0, 0])[:3];
    . as $simulators
    | ($sdk_version | version_components) as $sdk
    | [
        .runtimes[]
        | select(.isAvailable == true
            and (.identifier | startswith("com.apple.CoreSimulator.SimRuntime.iOS-")))
        | (.version | version_components) as $version
        | select($version <= $sdk)
        | .identifier as $runtime
        | $simulators.devices[$runtime][]?
        | select(.isAvailable == true and (.name | startswith($device_prefix)))
        | select($preferred_name == "" or .name == $preferred_name)
        | select($preferred_id == "" or .udid == $preferred_id)
        | {name, udid, version: $version}
      ]
    | sort_by(.version, .name, .udid) | last
    | if . == null then empty else [.udid, .name] | @tsv end
  ' <<< "$simulator_json")"

if [[ -z "$device" ]]; then
  echo "No matching $device_prefix simulator is compatible with iOS SDK $sdk_version." >&2
  xcrun simctl list runtimes available >&2
  xcrun simctl list devices available >&2
  exit 1
fi

IFS=$'\t' read -r device_id device_name <<< "$device"
results_root="${UI_TEST_RESULTS_DIR:-$repo_root/build/ui-tests}"
mkdir -p "$results_root"
results_root="$(cd "$results_root" && pwd)"
run_dir="$(mktemp -d "$results_root/$device_family.XXXXXX")"
result_bundle="$run_dir/CodexBarIOSUITests.xcresult"
echo "Running UI journeys on $device_name ($device_id). Results: $run_dir"

# Preserve xcodebuild's exit status even if diagnostic extraction fails.
preserve_failure_attachments() {
  local exit_status=$?
  if [[ $exit_status -ne 0 && -d "$result_bundle" ]]; then
    xcrun xcresulttool export attachments \
      --path "$result_bundle" \
      --output-path "$run_dir/failure-attachments" || true
  fi
  exit "$exit_status"
}
trap preserve_failure_attachments EXIT

xcodebuild \
  -project "$repo_root/CodexBarIOS.xcodeproj" \
  -scheme CodexBarIOSUITests \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath "${UI_TEST_DERIVED_DATA_DIR:-$repo_root/build/DerivedData-UI}" \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  CODE_SIGNING_ALLOWED=NO \
  test 2>&1 | tee "$run_dir/xcodebuild.log"

xcrun xcresulttool get test-results summary \
  --path "$result_bundle" > "$run_dir/summary.json"

# All five named account journeys must run on each destination. A skipped or empty
# suite can otherwise make xcodebuild return success without testing the flows.
if ! jq -e '
  .result == "Passed"
  and .totalTestCount == 5
  and .passedTests == 5
  and .failedTests == 0
  and .skippedTests == 0
  and .expectedFailures == 0
' "$run_dir/summary.json" > /dev/null; then
  cat "$run_dir/summary.json" >&2
  echo "Expected all five UI journeys to pass with zero skips on $device_name." >&2
  exit 1
fi
