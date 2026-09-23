# OpenCode phone sign-in

OpenCode Go and Zen use browser approval. In account settings, choose **Sign in
with OpenCode** or **Reconnect OpenCode**, then choose **Use browser sign-in**
or **Use private sign-in**. Browser sign-in can use accounts already signed in
on the device. Private sign-in starts a separate browser session. Check the
OpenCode account and approve the workspace you want to track. CodexBar returns automatically, verifies available
Go usage or Zen balance, then saves the credentials in that account's Keychain
entry. No JSON, workspace ID, copied token, or desktop session is required.

Removing a saved credential disconnects that CodexBar account on this device.
It does not revoke access at OpenCode. Account customization and history remain.
Reconnection cannot silently replace an existing account's workspace or a saved
Console credential's user identity. Add another
CodexBar account to track a different workspace.

## Provider contract

The initial embedded-browser implementation was rejected during review. Google
[does not support authorization in embedded user agents](https://developers.google.com/identity/protocols/oauth2/native-app#authorization-errors-disallowed-useragent).
Production sign-in uses `ASWebAuthenticationSession`. OpenCode explicitly selects
whether it requests a private session; all other callers keep the presenter's
private default. CodexBar does not inspect browser cookies, passwords, or page
contents. Closing the browser returns to the session choices and cancels that
attempt's polling. A retry creates a fresh device challenge; stale completion
cannot finish the new attempt.

The current [OpenCode Console](https://opencode.ai/console/) provides a device
approval flow. Its deployed [client schemas](https://opencode.ai/console/assets/index-CGGre-5H.js)
and [Go client](https://opencode.ai/console/assets/queries-DUtsFTY0.js) define:

- `POST /console/auth/device/code`, with CodexBar's own public client label
  `codexbar-ios` and `supports_org_scope: true`.
- A provider-hosted `/console/device` approval page with workspace selection.
- `POST /console/auth/device/token`, supporting device-code and refresh grants.
- `GET /console/auth/session` for the authorized user's identity.
- `GET /console/api/go/status` and `GET /console/api/billing/status`, authenticated
  by the resulting bearer token and `x-org-id` workspace header.

An unauthenticated development probe returned a device challenge, a 900-second
expiry, and a five-second polling interval. A later unapproved token poll returned
`expired_token`. Those probes verify endpoint availability, not successful
account authorization. These are first-party Console contracts, not a claim of
public API stability. Endpoint or schema changes must fail visibly rather than
fall back to credential pasting.

## Credential and usage handling

CodexBar accepts approval URLs only at the exact HTTPS Console device path.
Polling respects the provider interval, pending approval, slow-down responses,
denial, expiry, and cancellation. Token requests and usage requests have no shared
cookie storage and reject redirects.

The returned workspace scope must agree with the authenticated identity before
usage verification. Go data for a different workspace member is not displayed.
Only verified current Go windows or a real Zen balance can establish a connected
account. Go and balance failures remain independent. The Console's microcent
amounts are converted using 100,000,000 microcents per dollar. Go history keeps
its existing metric identities and uses server reset times. An inactive rolling
window has no invented reset date.

Credentials are stored per CodexBar account. Expiring tokens use the shared
credential-refresh coordinator and check the current stored credential before
saving a replacement. Cache identity follows the workspace and user, so routine
token renewal does not discard the last known value of an unavailable component.
A transient renewal failure can use the previous token only before its actual
expiry and only while that exact credential remains saved. Removed, replaced,
rejected, and expired credentials are not used as a fallback. Failed persistence
does not establish a new connection. Cancellation and failed verification leave
the saved account unchanged.

Older saved dashboard credentials remain readable for compatibility. New setup
and reconnection never ask the user to obtain or paste one.

## Google device verification

[Issue #356](https://github.com/HemSoft/codexbar-ios/issues/356) reports Google's
unrecognized-device verification message, not `disallowed_useragent`. Google's
account-specific decision has not been reproduced by the agent. A baseline UI
test reproduced the app-side limitation: there was no normal-browser choice.

[Apple documents](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/prefersephemeralwebbrowsersession)
that requesting an ephemeral session prevents sharing browser cookies/data with
the normal browser session. The app previously always made that request.
The scoped correction offers an explicit normal-browser option while retaining
private sign-in. The actual session factory is tested with both preferences;
this is not a simulation or proof of Google's risk decision.

If Google says it cannot recognize the device, close the browser and choose
**Use browser sign-in**. Google may still require identity verification. Only
the account owner can complete passwords, MFA, and recovery challenges. Follow
[Google's identity-verification guidance](https://support.google.com/accounts/answer/7299973)
when necessary; do not disable account security or repeatedly retry sign-in.

Existing Console credentials protect both workspace and user identity before
usage validation and again before saving. Legacy dashboard credentials have no
saved Console user ID, so their existing workspace boundary remains the available
reconnect check. Tokens and provider requests still use cookie-free networking.

## Local validation

Run local auth and Console parsing regressions without adding automatic CI work:

```sh
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
  xcrun swift test --filter OpenCodeAuthTests
```

`OpenCodeSignInUITests` belongs to the existing manually dispatched UI target.
Its UUID-isolated fixture simulates browser approval and never opens a provider
account or uses live credentials. It covers disconnected setup, cancellation,
workspace selection, both browser choices, returning from a dismissed browser,
credential removal, reconnection, relaunch, and verification failure. Synthetic screenshots are not proof of live Google or GitHub sign-in.

Franz owns the final live-account sign-in and Go/Zen quota comparison. Those
checks remain pending and are not a prerequisite for agent build delivery.
