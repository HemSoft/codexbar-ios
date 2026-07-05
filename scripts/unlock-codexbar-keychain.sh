#!/usr/bin/env bash
set -euo pipefail

SERVICE="codexbar-dev-keychain-password"
ACCOUNT="${USER:?}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/codexbar-dev.keychain-db"

password="$(security find-generic-password -w \
  -a "$ACCOUNT" \
  -s "$SERVICE" \
  "$LOGIN_KEYCHAIN")"

security unlock-keychain -p "$password" "$SIGNING_KEYCHAIN"
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$password" \
  "$SIGNING_KEYCHAIN" >/dev/null

security list-keychains -d user -s \
  "$SIGNING_KEYCHAIN" \
  "$LOGIN_KEYCHAIN" \
  /Library/Keychains/System.keychain
security default-keychain -d user -s "$LOGIN_KEYCHAIN"

echo "Unlocked CodexBar signing keychain and restored signing search order."
