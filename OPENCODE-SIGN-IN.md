# OpenCode phone sign-in

OpenCode account settings offer **Sign in with OpenCode** or **Reconnect
OpenCode**. A new private website session opens each time. Sign in using the
provider's website, choose the workspace there, then select **Connect this
workspace**. CodexBar verifies actual Go usage or Zen balance before saving the
session in the account's Keychain entry and returning to settings.

Removing the saved credential disconnects this device. It does not revoke the
provider's session remotely or remove account preferences/history. Reconnecting
an existing entry must select the same workspace. Add another OpenCode account
to track a different workspace. Existing saved credentials remain readable.

## Provider contract

Verified September 22, 2026:

- [Go documentation](https://opencode.ai/docs/go/) links to
  [OpenCode sign-in](https://opencode.ai/auth).
- An unauthenticated GET follows the provider's redirect to
  `https://auth.opencode.ai/authorize`, with GitHub and Google sign-in choices.
- [Console auth source](https://github.com/anomalyco/opencode/blob/2406400f0aeb07b36d0495af4e05aaca49159832/packages/console/app/src/context/auth.ts)
  and its [callback](https://github.com/anomalyco/opencode/blob/2406400f0aeb07b36d0495af4e05aaca49159832/packages/console/app/src/routes/auth/%5B...callback%5D.ts)
  establish the HTTP-only `auth` cookie at the provider origin.
- The [workspace picker](https://github.com/anomalyco/opencode/blob/2406400f0aeb07b36d0495af4e05aaca49159832/packages/console/app/src/routes/workspace-picker.tsx)
  navigates to `/workspace/<id>`. CodexBar reads only the selected URL and the
  provider-scoped cookie, not passwords or page form values.

No supported third-party mobile dashboard OAuth grant has been verified.
OpenCode's OAuth discovery endpoint is not sufficient evidence that a new
mobile client can receive dashboard credentials. The implementation therefore
uses a nonpersistent WebKit session rather than inventing a client registration
or requesting users copy credentials. The embedded sign-in provider's behavior
can change. Upstream also contains console-migration redirects; an unrecognized
origin stays blocked instead of accepting an unverified session.

Only HTTPS navigation on the exact OpenCode, OpenCode auth, GitHub, and Google
Accounts origins is allowed. Verification rejects redirects and uses an
isolated URLSession with no shared cookie storage. Cancel and navigation errors
never display provider URLs or raw WebKit error text. A canceled attempt cannot
save a late result.

## Local regression checks

New tests are local/manual. Automatic CI jobs, destinations, triggers, retries,
and timeouts are unchanged; existing assertions are only updated for new copy.

```sh
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
  xcrun swift test --filter OpenCode

DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
  xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarIOSUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:CodexBarIOSUITests/OpenCodeSignInUITests \
  -skipPackagePluginValidation test
```

Repeat the UI command with an available iPad destination. The simulator-only
UUID-scoped UI fixture uses synthetic website pages and credentials. It covers
workspace selection, saving, cancellation, verification failure/retry, removal,
reconnection, and relaunch without contacting a provider. The SwiftPM tests cover
origin/cookie validation, workspace isolation, actual-data verification, failed
Keychain writes, and preserving configuration when removing credentials.

Live GitHub/Google sign-in, MFA, workspace selection, and Go/Zen quota comparison
remain pending for Franz. Synthetic tests do not establish live provider login
compatibility. Live credentials and account screenshots must remain local.
