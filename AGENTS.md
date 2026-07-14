# CodexBar iOS Agent Notes

## Changelog and Release History

`CHANGELOG.md` is the source of truth for CodexBar release history. Maintaining
it is part of completing a change, not a cleanup task for the end of a release.
The history is used to prepare App Store **What's New** text, release notes,
support responses, launch announcements, and other marketing material, so it
must remain accurate, readable, and useful to people outside the codebase.

- Update the current `Unreleased` version in the same branch or PR as every
  user-visible addition, change, fix, or removal.
- Describe the user benefit and observable behavior. Avoid implementation-only
  language in customer-facing sections.
- Keep development, build, signing, and release-process changes under a
  separate `Developer Experience` heading so they do not leak into App Store
  copy.
- Link the relevant GitHub issue when it provides useful context, and make sure
  the changelog never promises work that is only planned or still incomplete.
- Preserve published version sections as historical records. Do not rewrite or
  remove released entries except to correct a factual error.
- Before an App Store submission, replace `Unreleased` with the release date,
  verify the section matches the shipped `MARKETING_VERSION`, and derive the
  App Store and marketing copy from those verified entries.
- After cutting a release, start the next version's `Unreleased` section before
  additional product work lands. Do not reconstruct release history from git
  commits at the last minute.

## Pull Request Reviewers

This repository has three automated PR reviewers. Treat all of them as part of
the normal merge-readiness loop: triage actionable feedback, fix or document
each thread, explicitly resolve addressed review threads in GitHub, and request
fresh reviews after meaningful updates.

| Reviewer | GitHub identity / check | Trigger |
| --- | --- | --- |
| Codex | `chatgpt-codex-connector` | `@codex review` on the PR, or automatic Codex cloud reviews when enabled |
| CodeRabbit | `coderabbitai` / `CodeRabbit` check | `@coderabbitai review` on the PR |
| Cursor Bugbot | `cursor` / `Cursor Bugbot` check | `cursor review` or `bugbot run` on the PR, or automatic Bugbot reviews when enabled in the Cursor dashboard |

Notes for agents:

- Request Codex and CodeRabbit through PR trigger comments, not the Copilot
  `requestReviewsByLogin` API path.
- Bugbot is configured on this repo through the Cursor GitHub app. Prefer
  `cursor review` when requesting a manual rerun.
- None of these reviewers is a guaranteed branch-protection approval by itself.
  Report the actual GitHub review/check state for the current head SHA.
- Before declaring a PR ready, confirm actionable threads from all reviewers
  that left feedback are addressed and explicitly resolved, and that normal PR
  checks pass for the current head.

Example manual review requests on a PR:

```text
@codex review
@coderabbitai review
cursor review
```

## Deploying to a Connected iPhone

Use Xcode explicitly; the active `xcode-select` path may point at Command Line Tools.

1. Find the connected device if needed:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices
   ```

2. Build for the phone with automatic provisioning enabled:

   ```sh
   ./scripts/with-codexbar-keychain.sh env \
     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcodebuild \
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

Current known phone id from the successful deploy on 2026-07-10:

```text
B80ABFAB-DB0A-50CB-BA19-A21AA136BB3A
```

If remote launch fails because the phone is locked, the install may still have succeeded. Ask the user to unlock the phone or open the app manually.

## Signing Recovery

Preferred steady state as of 2026-07-10:

- Use the dedicated CodexBar signing keychain, not the crowded login keychain, for iPhone deploy signing.
- Keychain path:

  ```text
  ~/Library/Keychains/codexbar-dev.keychain-db
  ```

- Stable Apple Development identity currently used by successful phone builds:

  ```text
  9E66931E7240D215D3210DF222DD75E47A379078
  ```

- The user set a known password for this keychain through a hidden macOS prompt. Do not ask for or store that password in chat or repo files.
- The password is saved outside the macOS login keychain in an owner-only local file:

  ```text
  ~/Library/Application Support/CodexBar/signing-keychain-password
  mode: 600
  ```

- Do not move this password back into a login-keychain generic password item. Updating the old `codexbar-dev-keychain-password` item triggers an ACL prompt for the unknown legacy login-keychain password.

- To unlock and verify the dedicated signing keychain without adding it to the global search list, run:

  ```sh
  ./scripts/unlock-codexbar-keychain.sh
  ```

- The normal keychain search list must not contain `codexbar-dev.keychain-db`. It locks on sleep, and unrelated system services otherwise prompt for its password while searching the global list.
- The default keychain should remain `login.keychain-db` so normal app/password storage still behaves normally.
- Run Xcode signing commands through the temporary-search-list wrapper. It adds `codexbar-dev.keychain-db` for the duration of the command and restores the normal list on success, failure, or interruption:

  ```sh
  ./scripts/with-codexbar-keychain.sh env \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild \
      -allowProvisioningUpdates \
      -allowProvisioningDeviceRegistration \
      -project CodexBarIOS.xcodeproj \
      -scheme CodexBarIOS \
      -destination 'id=<DEVICE_ID>' \
      build
  ```

Verify the signing state before changing certificates:

```sh
security list-keychains -d user
security default-keychain
security find-identity -v -p codesigning ~/Library/Keychains/codexbar-dev.keychain-db
```

Expected shape:

```text
"/Users/home/Library/Keychains/login.keychain-db"
"/Library/Keychains/System.keychain"
"/Users/home/Library/Keychains/login.keychain-db"
1 valid identity found in codexbar-dev.keychain-db
```

If the dedicated keychain is locked after reboot, first try the helper script:

```sh
./scripts/unlock-codexbar-keychain.sh
```

If the dedicated keychain or owner-only password file is missing or unusable, run the reset helper. It asks for a new password twice through hidden local dialogs and backs up the previous signing keychain before recreating it:

```sh
./scripts/reset-codexbar-keychain.sh
```

After a reset, the dedicated keychain has no signing identity. If Xcode says an existing development certificate has no private key, revoke only the stale Apple Development certificate in the developer portal. Then temporarily make the dedicated keychain the default and isolate the search list while running `xcodebuild -allowProvisioningUpdates`; this forces the replacement certificate and private key into the dedicated keychain. Restore `login.keychain-db` as the default afterward.

If `codexbar-dev.keychain-db` is ever left in the global search list, restore the normal state by running the unlock helper or these commands:

```sh
security list-keychains -d user -s \
  "$HOME/Library/Keychains/login.keychain-db" \
  /Library/Keychains/System.keychain
security default-keychain -d user -s "$HOME/Library/Keychains/login.keychain-db"
```

Do not keep deleting failing login-keychain identities or generating new certificates unless the dedicated keychain is missing or unusable. The old login keychain had dozens of duplicate `Apple Development: Franz Hemmer (ZBX7LBML7H)` identities, which caused nondeterministic Xcode signing selection and repeated `CodeSign` hangs.

The 2026-07-10 wake-from-sleep prompt flood was caused by leaving the lock-on-sleep `codexbar-dev.keychain-db` first in the global search list. Prompts from `sharingd`, `com.apple.iCloudHelper`, and other services named the CodexBar keychain because those services searched every configured keychain. Keep it out of the normal list and expose it only through `with-codexbar-keychain.sh`. A prompt that explicitly names `login` instead is a separate login-keychain issue.

The 2026-07-10 recovery succeeded end to end: Xcode created identity `9E66931E7240D215D3210DF222DD75E47A379078` in `codexbar-dev.keychain-db`, the device build succeeded, and `devicectl` installed and launched `com.hemsoft.CodexBarIOS` on the phone.

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
