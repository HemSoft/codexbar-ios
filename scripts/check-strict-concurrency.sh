#!/bin/bash

set -euo pipefail

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

xcodebuild -quiet \
  -project CodexBarIOS.xcodeproj \
  -scheme CodexBarIOS \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  clean build

ios_test_log="$(mktemp -t codexbar-strict-ios-tests)"
watch_test_log="$(mktemp -t codexbar-strict-watch-tests)"
trap 'rm -f "$ios_test_log" "$watch_test_log"' EXIT

check_watch_connectivity_diagnostics() {
  local log_file="$1"
  if grep -E \
    '(WatchSnapshotCoordinator|WatchDashboardSnapshot|WatchConnectivityStore|DashboardAndSettingsTests|WatchDashboardStateTests)\.swift:[0-9]+:[0-9]+: (warning|error):' \
    "$log_file"; then
    echo "Strict-concurrency diagnostics found in WatchConnectivity sources or tests." >&2
    return 1
  fi
}

if ! xcodebuild -quiet \
  -project CodexBarIOS.xcodeproj \
  -scheme CodexBarIOS \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build-for-testing >"$ios_test_log" 2>&1; then
  cat "$ios_test_log"
  exit 1
fi
check_watch_connectivity_diagnostics "$ios_test_log"

if ! xcodebuild -quiet \
  -project CodexBarIOS.xcodeproj \
  -scheme CodexBarWatchTests \
  -destination "generic/platform=watchOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build-for-testing >"$watch_test_log" 2>&1; then
  cat "$watch_test_log"
  exit 1
fi
check_watch_connectivity_diagnostics "$watch_test_log"
