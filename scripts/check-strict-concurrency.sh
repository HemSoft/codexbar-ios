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
