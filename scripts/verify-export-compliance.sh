#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "$script_dir/.." && pwd)"

usage() {
  echo "Usage: $0 source | bundle <path-to-app-or-archive>" >&2
}

read_plist_value() {
  local plist_path="$1"
  local key="$2"

  plutil -extract "$key" raw -o - "$plist_path" 2>/dev/null
}

verify_plist() {
  local label="$1"
  local plist_path="$2"
  local declaration
  local declaration_type

  if [[ ! -f "$plist_path" ]]; then
    echo "Missing Info.plist for $label: $plist_path" >&2
    return 1
  fi

  if ! declaration="$(read_plist_value "$plist_path" ITSAppUsesNonExemptEncryption)"; then
    echo "$label omits ITSAppUsesNonExemptEncryption: $plist_path" >&2
    return 1
  fi

  if ! declaration_type="$(plutil -type ITSAppUsesNonExemptEncryption "$plist_path" 2>/dev/null)"; then
    echo "$label has an unreadable ITSAppUsesNonExemptEncryption declaration: $plist_path" >&2
    return 1
  fi

  if [[ "$declaration_type" != "bool" ]]; then
    echo "$label has non-Boolean ITSAppUsesNonExemptEncryption type=$declaration_type: $plist_path" >&2
    return 1
  fi

  if [[ "$declaration" != "false" ]]; then
    echo "$label has unexpected ITSAppUsesNonExemptEncryption=$declaration: $plist_path" >&2
    return 1
  fi

  echo "Verified $label declares ITSAppUsesNonExemptEncryption=false."
}

verify_source_plists() {
  verify_plist "iOS app source" "$repository_dir/CodexBarIOS/Info.plist"
  verify_plist "iOS widget source" "$repository_dir/CodexBarIOSWidget/Info.plist"
  verify_plist "Watch app source" "$repository_dir/CodexBarWatch/Info.plist"
  verify_plist "Watch widget source" "$repository_dir/CodexBarWatchWidget/Info.plist"
}

verify_built_bundles() {
  local product_path="$1"
  local search_root="$product_path"
  local bundle_path
  local bundle_identifier
  local executable_name
  local found_count=0
  local expected_identifier
  local -a found_identifiers=()
  local -a expected_identifiers=(
    "com.hemsoft.CodexBarIOS"
    "com.hemsoft.CodexBarIOS.CodexBarIOSWidget"
    "com.hemsoft.CodexBarIOS.watchkitapp"
    "com.hemsoft.CodexBarIOS.watchkitapp.CodexBarWatchWidget"
  )

  if [[ ! -e "$product_path" ]]; then
    echo "Built product does not exist: $product_path" >&2
    return 1
  fi

  if [[ -d "$product_path/Products/Applications" ]]; then
    search_root="$product_path/Products/Applications"
  fi

  while IFS= read -r bundle_path; do
    if ! executable_name="$(read_plist_value "$bundle_path/Info.plist" CFBundleExecutable)"; then
      continue
    fi
    if [[ -z "$executable_name" ]]; then
      continue
    fi
    if ! bundle_identifier="$(read_plist_value "$bundle_path/Info.plist" CFBundleIdentifier)"; then
      echo "Executable bundle omits CFBundleIdentifier: $bundle_path" >&2
      return 1
    fi

    verify_plist "$bundle_identifier built bundle" "$bundle_path/Info.plist"
    found_identifiers+=("$bundle_identifier")
    found_count=$((found_count + 1))
  done < <(find "$search_root" -type d \( -name '*.app' -o -name '*.appex' \) -print | sort)

  for expected_identifier in "${expected_identifiers[@]}"; do
    if [[ " ${found_identifiers[*]} " != *" $expected_identifier "* ]]; then
      echo "Missing submitted executable bundle: $expected_identifier" >&2
      return 1
    fi
  done

  if [[ "$found_count" -lt "${#expected_identifiers[@]}" ]]; then
    echo "Expected at least ${#expected_identifiers[@]} submitted executable bundles, found $found_count." >&2
    return 1
  fi

  echo "Verified $found_count built executable bundles, including all four submitted CodexBar products."
}

case "${1:-}" in
  source)
    if [[ "$#" -ne 1 ]]; then
      usage
      exit 2
    fi
    verify_source_plists
    ;;
  bundle)
    if [[ "$#" -ne 2 ]]; then
      usage
      exit 2
    fi
    verify_built_bundles "$2"
    ;;
  *)
    usage
    exit 2
    ;;
esac
