#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
: "${SECURITY_DERIVED_DATA:?Set SECURITY_DERIVED_DATA to a fresh build directory}"
export DEVELOPER_DIR

# A fresh directory prevents cached object files from bypassing extraction.
if [[ -e "$SECURITY_DERIVED_DATA" ]]; then
  echo "Security build directory must not already exist: $SECURITY_DERIVED_DATA" >&2
  exit 1
fi

xcodebuild \
  -project CodexBarIOS.xcodeproj \
  -scheme CodexBarIOS \
  -configuration Debug \
  -skipPackagePluginValidation \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$SECURITY_DERIVED_DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  build

# The temporary positive fixture is compiled, never linked to or run by the app.
if [[ -f scripts/security-analysis/fixtures/Positive.swift ]]; then
  xcrun swiftc -parse-as-library -emit-module \
    scripts/security-analysis/fixtures/Positive.swift \
    -module-name SecurityPositiveFixture \
    -emit-module-path "$SECURITY_DERIVED_DATA/SecurityPositiveFixture.swiftmodule"
fi
