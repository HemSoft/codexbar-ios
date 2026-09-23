# OpenCode phone sign-in

OpenCode Go and Zen use browser approval. In account settings, choose **Sign in
with OpenCode** or **Reconnect OpenCode**, then choose **Use browser sign-in**
or **Use private sign-in**. Browser sign-in can use accounts already signed in
on the device. Private sign-in starts a separate browser session. Check the
OpenCode account and approve the workspace you want to track. CodexBar closes the
browser after receiving a valid device-grant token, then verifies the account
and available Go usage or Zen balance before saving credentials in that account's
Keychain entry. If the website reports approval but stays open, close the browser
to let CodexBar check the current attempt. **Cancel** inside CodexBar stops
sign-in. No JSON, workspace ID, copied token, or desktop session is required.

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
contents. Closing the browser retains the current device exchange for one
approval check, without opening another browser or issuing a second token
request in parallel. The existing polling interval still applies. A pending reply
from a request started before browser dismissal still permits one fresh check.
A pending response to that post-close check returns to the choices; a valid token
continues identity and usage verification in the app. The post-close approval check stops after 30 seconds
if no token has arrived. Denial, expiry and errors offer recovery without saving
a connection. A retry creates a fresh challenge, and stale completion cannot
finish the new attempt. Canceling in the app or removing the account immediately
invalidates the attempt, including a pending identity or usage check.

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

## Completion after website approval

[Issue #358](https://github.com/HemSoft/codexbar-ios/issues/358) records a successful
website approval followed by a browser that stayed open, cancellation, and a
second attempt that worked. No first-attempt network trace exists. The website's
message does not establish token receipt, verified usage or Keychain persistence.

A local native regression reproduces an app-owned failure: browser dismissal
previously canceled the authorization task and discarded an approved result
still completing. The same staged test now completes that first attempt. Separate
transport and native tests verify that token receipt closes the browser before
the identity request completes, without reporting the account connected. These
are controlled tests of the real polling and session modules, not a reproduction
of Google's decision or proof of the original live delay.

The stages are device challenge, browser approval, token exchange, identity
verification, usage verification, and account-scoped persistence. The app shows
**Checking OpenCode approval** on browser return and **Verifying OpenCode account**
after token receipt. It does not log approval codes, tokens, browser URLs or
provider identities to describe those stages. A browser close while approval is
still unavailable returns to the choices with an explanation. Explicit app
cancellation, expiry, denial, failed verification and failed storage never create
a new connection.

## Local validation

Run local auth and Console parsing regressions without adding automatic CI work:

```sh
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
  xcrun swift test --filter OpenCodeAuthTests
```

Run the same local-only target on an iPhone simulator to include the native
system-browser factory and completion-lifecycle checks. They verify both browser
modes, dismissal during an approved exchange, early browser return, explicit app
cancellation, a bounded post-close check, and fresh retry with stale callbacks
ignored. The tests do not open a real browser:

```sh
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
  ./scripts/run-opencode-native-auth-tests.sh
```

The helper copies the package sources into a temporary directory so Xcode does
not select the app project. It retains results under `DerivedData/OpenCodeNativeAuth`
and removes its temporary copy. Set `OPENCODE_AUTH_DESTINATION`,
`OPENCODE_AUTH_DERIVED_DATA`, or `OPENCODE_AUTH_RESULT_BUNDLE` to override those
locations. The target retains its pinned lint plugin. Neither command runs in
automatic CI; the automatic iOS test file is unchanged.

`OpenCodeSignInUITests` belongs to the existing manually dispatched UI target.
Its UUID-isolated fixture simulates browser approval and never opens a provider
account or uses live credentials. It covers disconnected setup, cancellation,
workspace selection, both browser choices, returning from a dismissed browser,
approval-check and account-verification progress, cancellation while checking,
credential removal, reconnection, relaunch, and verification failure. Synthetic
screenshots prove those app states, not live Google or GitHub sign-in.

Franz confirmed that setup eventually succeeded before this completion fix.
First-pass reliability with the fix and Go/Zen quota comparison remain live
checks for Franz, not prerequisites for independent validation and build delivery.
Do not disconnect a working account merely to collect evidence.
