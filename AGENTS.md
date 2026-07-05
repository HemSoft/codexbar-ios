# CodexBar iOS Agent Notes

## Deploying to a Connected iPhone

Use Xcode explicitly; the active `xcode-select` path may point at Command Line Tools.

1. Find the connected device if needed:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices
   ```

2. Build for the phone with automatic provisioning enabled:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
     -allowProvisioningUpdates \
     -allowProvisioningDeviceRegistration \
     -project CodexBarIOS.xcodeproj \
     -scheme CodexBarIOS \
     -destination 'id=<DEVICE_ID>' \
     build
   ```

3. Install the built app:

   ```sh
   APP="$HOME/Library/Developer/Xcode/DerivedData/CodexBarIOS-dyhhtrkbrowzvbhasoojmaczkxuz/Build/Products/Debug-iphoneos/CodexBarIOS.app"
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
     --device <DEVICE_ID> \
     "$APP"
   ```

4. Launch it:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch \
     --device <DEVICE_ID> \
     com.hemsoft.CodexBarIOS
   ```

5. Verify it is running:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device info processes \
     --device <DEVICE_ID> | rg -n 'CodexBar|com\.hemsoft' -C 2
   ```

Current known phone id from the successful deploy on 2026-07-02:

```text
B80ABFAB-DB0A-50CB-BA19-A21AA136BB3A
```

If remote launch fails because the phone is locked, the install may still have succeeded. Ask the user to unlock the phone or open the app manually.

## Signing Recovery

Preferred steady state as of 2026-07-04:

- Use the dedicated CodexBar signing keychain, not the crowded login keychain, for iPhone deploy signing.
- Keychain path:

  ```text
  ~/Library/Keychains/codexbar-dev.keychain-db
  ```

- Stable Apple Development identity currently used by successful phone builds:

  ```text
  A7F919D15116968EBC5B3BC3539D2DA780E40D55
  ```

- The user set a known password for this keychain through a hidden macOS prompt. Do not ask for or store that password in chat or repo files.
- The password is saved locally in the user's login keychain as a generic password item:

  ```text
  service: codexbar-dev-keychain-password
  account: $USER
  keychain: ~/Library/Keychains/login.keychain-db
  ```

- To unlock the dedicated signing keychain noninteractively before a deploy, run:

  ```sh
  ./scripts/unlock-codexbar-keychain.sh
  ```

- The keychain search list should keep `codexbar-dev.keychain-db` first so Xcode finds the clean signing identity before the many duplicate Apple Development identities in `login.keychain-db`.
- The default keychain should remain `login.keychain-db` so normal app/password storage still behaves normally.

Verify the signing state before changing certificates:

```sh
security list-keychains -d user
security default-keychain
security find-identity -v -p codesigning ~/Library/Keychains/codexbar-dev.keychain-db
```

Expected shape:

```text
"/Users/home/Library/Keychains/codexbar-dev.keychain-db"
"/Users/home/Library/Keychains/login.keychain-db"
"/Library/Keychains/System.keychain"
"/Users/home/Library/Keychains/login.keychain-db"
1 valid identity found in codexbar-dev.keychain-db
```

If the dedicated keychain is locked after reboot, first try the helper script:

```sh
./scripts/unlock-codexbar-keychain.sh
```

If the saved login-keychain item is missing or access to it fails, ask the user to enter the known CodexBar signing keychain password through a local macOS prompt, then save/update the login-keychain item and refresh partition-list access:

```sh
KC="$HOME/Library/Keychains/codexbar-dev.keychain-db"
SERVICE="codexbar-dev-keychain-password"
LOGIN="$HOME/Library/Keychains/login.keychain-db"
PW=$(osascript <<'OSA'
display dialog "Enter the CodexBar signing keychain password." default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue"
text returned of result
OSA
)
security add-generic-password -U \
  -a "$USER" \
  -s "$SERVICE" \
  -l "CodexBar development signing keychain password" \
  -w "$PW" \
  -T /usr/bin/security \
  "$LOGIN"
security unlock-keychain -p "$PW" "$KC"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC"
```

If future Xcode builds start choosing identities from `login.keychain-db`, restore the search list without changing the default keychain:

```sh
security list-keychains -d user -s \
  "$HOME/Library/Keychains/codexbar-dev.keychain-db" \
  "$HOME/Library/Keychains/login.keychain-db" \
  /Library/Keychains/System.keychain
security default-keychain -d user -s "$HOME/Library/Keychains/login.keychain-db"
```

Do not keep deleting failing login-keychain identities or generating new certificates unless the dedicated keychain is missing or unusable. The old login keychain had dozens of duplicate `Apple Development: Franz Hemmer (ZBX7LBML7H)` identities, which caused nondeterministic Xcode signing selection and repeated `CodeSign` hangs.

### Legacy Recovery

If the phone build stalls at `CodeSign` and then fails with `errSecInternalComponent`, Xcode likely generated or selected a development signing identity whose private key is not usable from the current session.

Use this only if the dedicated `codexbar-dev.keychain-db` path above is unavailable. The old recovery was:

1. Check available signing identities:

   ```sh
   security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db
   ```

2. Move the active generated provisioning profile out of Xcode's active profile folder, keeping a backup:

   ```sh
   BACKUP="$HOME/Library/Developer/Xcode/UserData/CodexBarSigningBackups/CodexBar-backup-$(date +%Y%m%d-%H%M%S)"
   mkdir -p "$BACKUP/Provisioning Profiles"
   mv "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/<PROFILE_UUID>.mobileprovision" \
     "$BACKUP/Provisioning Profiles/"
   ```

3. Remove only the failing identity fingerprint reported in the failed `codesign --sign <FINGERPRINT>` line:

   ```sh
   security delete-certificate -Z <FAILING_CERT_SHA1> ~/Library/Keychains/login.keychain-db
   ```

4. Re-run the phone build command above. Xcode should regenerate/select a usable profile and sign successfully.

On 2026-07-02, the build succeeded after removing the failing identity `100D8E7C0C525C2EECEF657744D259F3D1FD2E2B`; the next build signed with `80BBD65F3B7634FEF75DBCA7B0F65A6C6E9AF420`.

## Browser Auth Takeaways

- For Claude browser auth, search current public docs/issues before changing the flow. Claude Code currently expects a localhost callback style such as `http://localhost:<port>/callback`.
- Start the local callback listener before opening Safari/`ASWebAuthenticationSession`, and keep the exact redirect URI consistent between authorize and token exchange.
- Browser-session providers should only become configured after their secret/token is saved. A suggested account label is not proof of auth.
- If auth appears to succeed but the provider is missing from settings/dashboard, check `ProviderConfigurationStore.isConfigurationReady`, `hasSecret`, account-specific keychain IDs, and status text first.
- After auth or signing changes, run simulator tests, then build/install/launch on the connected iPhone with `devicectl`.
