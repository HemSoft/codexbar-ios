#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "$script_dir/../.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

write_bundle_plist() {
  local bundle_path="$1"
  local bundle_identifier="$2"

  mkdir -p "$bundle_path"
  plutil -create xml1 "$bundle_path/Info.plist"
  plutil -insert CFBundleExecutable -string "FixtureExecutable" "$bundle_path/Info.plist"
  plutil -insert CFBundleIdentifier -string "$bundle_identifier" "$bundle_path/Info.plist"
  plutil -insert ITSAppUsesNonExemptEncryption -bool false "$bundle_path/Info.plist"
}

expect_omission_failure() {
  local bundle_path="$1"
  local failure_name="$2"

  plutil -remove ITSAppUsesNonExemptEncryption "$bundle_path/Info.plist"
  if "$repository_dir/scripts/verify-export-compliance.sh" bundle "$fixture_app" \
    >"$temporary_dir/$failure_name.stdout" \
    2>"$temporary_dir/$failure_name.stderr"; then
    echo "Expected a missing declaration to fail verification." >&2
    exit 1
  fi

  if ! grep -q "omits ITSAppUsesNonExemptEncryption" \
    "$temporary_dir/$failure_name.stderr"; then
    echo "Expected the failure to identify the omitted declaration." >&2
    cat "$temporary_dir/$failure_name.stderr" >&2
    exit 1
  fi
}

fixture_app="$temporary_dir/CodexBarIOS.app"
write_bundle_plist "$fixture_app" "com.hemsoft.CodexBarIOS"
write_bundle_plist \
  "$fixture_app/PlugIns/CodexBarIOSWidget.appex" \
  "com.hemsoft.CodexBarIOS.CodexBarIOSWidget"
write_bundle_plist \
  "$fixture_app/Watch/CodexBarWatch.app" \
  "com.hemsoft.CodexBarIOS.watchkitapp"
write_bundle_plist \
  "$fixture_app/Watch/CodexBarWatch.app/PlugIns/CodexBarWatchWidget.appex" \
  "com.hemsoft.CodexBarIOS.watchkitapp.CodexBarWatchWidget"

"$repository_dir/scripts/verify-export-compliance.sh" source
"$repository_dir/scripts/verify-export-compliance.sh" bundle "$fixture_app"

expect_omission_failure "$fixture_app/Watch/CodexBarWatch.app" "current-bundle-omission"

plutil -insert ITSAppUsesNonExemptEncryption -bool false \
  "$fixture_app/Watch/CodexBarWatch.app/Info.plist"
future_bundle="$fixture_app/PlugIns/FutureSubmittedProduct.appex"
write_bundle_plist "$future_bundle" "com.hemsoft.CodexBarIOS.FutureSubmittedProduct"
expect_omission_failure "$future_bundle" "future-bundle-omission"

echo "Export-compliance verification tests passed."
