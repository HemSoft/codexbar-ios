#!/usr/bin/env bash
# Local-only UIKit coverage for the SwiftPM auth target; never called by automatic CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-opencode-native.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT

unset OPENROUTER_API_KEY OPENCODE_API_KEY CLIPROXYAPI_API_KEY SLACK_TOKEN
DESTINATION="${OPENCODE_AUTH_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=latest}"
DERIVED_DATA="${OPENCODE_AUTH_DERIVED_DATA:-$ROOT/DerivedData/OpenCodeNativeAuth}"
RESULT="${OPENCODE_AUTH_RESULT_BUNDLE:-$DERIVED_DATA/results-$(date +%Y%m%dT%H%M%S)-$$.xcresult}"

# Xcode otherwise selects the app project rather than the package in this repository.
# Copy sources, not dependency/build directories or links to another checkout.
for directory in CodexBarIOS OpenCodeAuthTests SmokeTests GitHubBillingFixtureTests PerformanceBenchmarks; do
  cp -R "$ROOT/$directory" "$STAGING/$directory"
done
for file in Package.swift Package.resolved .swiftlint.yml; do
  cp "$ROOT/$file" "$STAGING/$file"
done

cd "$STAGING"
xcodebuild -scheme CodexBarIOS-Package \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT" \
  -skipPackagePluginValidation \
  -only-testing:OpenCodeAuthTests test
