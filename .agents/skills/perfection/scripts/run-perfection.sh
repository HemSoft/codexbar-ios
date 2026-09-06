#!/usr/bin/env bash
set -uo pipefail

readonly PROJECT="CodexBarIOS.xcodeproj"
readonly IOS_SCHEME="CodexBarIOS"
readonly WATCH_BUILD_SCHEME="CodexBarWatch"
readonly WATCH_TEST_SCHEME="CodexBarWatchTests"
readonly DEFAULT_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
output_root="${PERFECTION_OUTPUT_ROOT:-$repo_root/DerivedData/Perfection}"
developer_dir="${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}"
selected_gate=""
mode="audit"

usage() {
  cat <<'EOF'
Usage: run-perfection.sh [--gate NAME | --list | --status]

Run the seven local CodexBar iOS audit gates, or one selected gate.

Options:
  --gate NAME  Run one gate: swiftlint, strict-concurrency, ios-build,
               ios-tests, swiftpm-smoke, watch-build, or watch-tests.
  --list       List supported gate names.
  --status     Print the most recent local audit summary.
  -h, --help   Show this help.

Environment:
  DEVELOPER_DIR                   Xcode developer directory.
  PERFECTION_IOS_DESTINATION      Override the iOS simulator destination.
  PERFECTION_WATCH_DESTINATION    Override the watchOS simulator destination.
  PERFECTION_OUTPUT_ROOT          Override the artifact directory.
EOF
}

list_gates() {
  cat <<'EOF'
swiftlint
strict-concurrency
ios-build
ios-tests
swiftpm-smoke
watch-build
watch-tests
EOF
}

is_valid_gate() {
  case "$1" in
    swiftlint|strict-concurrency|ios-build|ios-tests|swiftpm-smoke|watch-build|watch-tests) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gate)
      if [[ $# -lt 2 ]]; then
        echo "--gate requires a gate name." >&2
        usage >&2
        exit 2
      fi
      selected_gate="$2"
      shift 2
      ;;
    --list)
      mode="list"
      shift
      ;;
    --status)
      mode="status"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$mode" == "list" ]]; then
  list_gates
  exit 0
fi

if [[ "$mode" == "status" ]]; then
  latest_summary="$output_root/latest-summary.md"
  if [[ ! -f "$latest_summary" ]]; then
    echo "No previous perfection audit summary was found at $latest_summary." >&2
    exit 1
  fi
  cat "$latest_summary"
  exit 0
fi

if [[ -n "$selected_gate" ]] && ! is_valid_gate "$selected_gate"; then
  echo "Unknown gate: $selected_gate" >&2
  echo "Valid gates:" >&2
  list_gates >&2
  exit 2
fi

if [[ ! -d "$developer_dir" ]]; then
  echo "Xcode developer directory not found: $developer_dir" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to select available simulators." >&2
  exit 1
fi

export DEVELOPER_DIR="$developer_dir"
cd "$repo_root"

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
run_dir="$output_root/$timestamp-$$"
derived_data="$run_dir/XcodeDerivedData"
mkdir -p "$run_dir" "$derived_data"

select_simulator_id() {
  local name_prefix="$1"
  xcrun simctl list devices available --json |
    jq -r --arg prefix "$name_prefix" '
      [.devices[] | .[] |
        select(.isAvailable == true and (.name | startswith($prefix)))]
      | first
      | .udid // empty
    '
}

ios_destination="${PERFECTION_IOS_DESTINATION:-}"
watch_destination="${PERFECTION_WATCH_DESTINATION:-}"

needs_ios=false
needs_watch=false
if [[ -z "$selected_gate" || "$selected_gate" == ios-* ]]; then
  needs_ios=true
fi
if [[ -z "$selected_gate" || "$selected_gate" == watch-* ]]; then
  needs_watch=true
fi

if [[ "$needs_ios" == true && -z "$ios_destination" ]]; then
  ios_device_id="$(select_simulator_id "iPhone")"
  if [[ -z "$ios_device_id" ]]; then
    xcrun simctl list devices available
    echo "No available iPhone simulator was found." >&2
    exit 1
  fi
  ios_destination="platform=iOS Simulator,id=$ios_device_id"
fi

if [[ "$needs_watch" == true && -z "$watch_destination" ]]; then
  watch_device_id="$("$repo_root/scripts/select-watch-simulator.sh")"
  watch_destination="platform=watchOS Simulator,id=$watch_device_id"
fi

gate_keys=()
gate_labels=()
gate_results=()
gate_logs=()
pass_count=0
fail_count=0

run_gate() {
  local key="$1"
  local label="$2"
  shift 2

  if [[ -n "$selected_gate" && "$selected_gate" != "$key" ]]; then
    return
  fi

  local log_path="$run_dir/$key.log"
  gate_keys[${#gate_keys[@]}]="$key"
  gate_labels[${#gate_labels[@]}]="$label"
  gate_logs[${#gate_logs[@]}]="$log_path"

  echo
  echo "=== $label ==="
  echo "Log: $log_path"

  if "$@" >"$log_path" 2>&1; then
    gate_results[${#gate_results[@]}]="PASS"
    pass_count=$((pass_count + 1))
    echo "PASS $label"
  else
    gate_results[${#gate_results[@]}]="FAIL"
    fail_count=$((fail_count + 1))
    echo "FAIL $label"
    echo "Last 40 log lines:"
    tail -40 "$log_path"
  fi
}

run_gate \
  "swiftlint" \
  "Repository SwiftLint" \
  xcrun swift package plugin \
    --allow-writing-to-package-directory \
    swiftlint lint \
    --reporter xcode .

run_gate \
  "strict-concurrency" \
  "Complete strict concurrency" \
  "$repo_root/scripts/check-strict-concurrency.sh"

run_gate \
  "ios-build" \
  "iOS simulator build" \
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$IOS_SCHEME" \
    -destination "$ios_destination" \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    build

run_gate \
  "ios-tests" \
  "iOS unit tests" \
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$IOS_SCHEME" \
    -destination "$ios_destination" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$run_dir/CodexBarIOSTests.xcresult" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    test

run_gate \
  "swiftpm-smoke" \
  "SwiftPM smoke tests" \
  xcrun swift run \
    --scratch-path "$run_dir/SwiftPM" \
    CodexBarIOSSmokeTests

run_gate \
  "watch-build" \
  "watchOS simulator build" \
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$WATCH_BUILD_SCHEME" \
    -destination "$watch_destination" \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    build

run_gate \
  "watch-tests" \
  "watchOS unit tests" \
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$WATCH_TEST_SCHEME" \
    -destination "$watch_destination" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$run_dir/CodexBarWatchTests.xcresult" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    test

summary_path="$run_dir/summary.md"
{
  echo "# CodexBar iOS Perfection Audit"
  echo
  echo "- Revision: \`$(git rev-parse --short HEAD 2>/dev/null || echo unknown)\`"
  echo "- Worktree: \`$(git status --porcelain | wc -l | tr -d ' ')\` changed path(s)"
  echo "- Artifacts: \`$run_dir\`"
  echo "- Selection: \`${selected_gate:-all seven local gates}\`"
  echo
  echo "| Gate | Status | Log |"
  echo "| --- | --- | --- |"
  index=0
  while [[ $index -lt ${#gate_keys[@]} ]]; do
    echo "| ${gate_labels[$index]} | ${gate_results[$index]} | \`${gate_logs[$index]}\` |"
    index=$((index + 1))
  done
  echo
  echo "**Perfection score: $pass_count / ${#gate_keys[@]} selected gates passing.**"
  echo
  echo "This audit does not run UI journeys, function coverage/risk analysis, security analysis, or performance budgets."
  echo "Verify those separate checks before declaring merge or release readiness; they are not counted as passing here."
} >"$summary_path"

cp "$summary_path" "$output_root/latest-summary.md"

echo
cat "$summary_path"

if [[ $fail_count -eq 0 ]]; then
  exit 0
fi
exit 1
