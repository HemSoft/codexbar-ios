# Cursor spending and direct Grok billing

Verified October 1, 2026 EDT for
[issue #388](https://github.com/HemSoft/codexbar-ios/issues/388).

## Sources and limits

The first-party Cursor 3.22.7 client installed from
[Cursor's distribution](https://cursor.com/download) identifies build
`37076c6c3f9e253c0fa2305197e45befd13a2260`. Its bundled client defines the
`GetCurrentPeriodUsage` and `GetSandUsageStatus` schemas and displays on-demand
spend using `individualUsed / 100` and the cap using `individualLimit / 100`.
It does not calculate that display from `individualRemaining`.
The inspected bundle's SHA-256 is
`a9157bf9054d3f27a2a6910c855e028bd5e38896fa74405ca2f766abff590cb8`.
This is installed first-party client evidence, not a captured account response.

[Cursor Bot plans](https://cursor.com/help/grok-bot/plans.md) and
[linked SuperGrok grants](https://cursor.com/help/grok-bot/supergrok.md) place
Bot allowances and on-demand spending under Cursor. Linked grants do not
create an additional direct Grok usage pool in CodexBar.

The separate Grok provider follows the
[first-party consumer billing model](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/extensions/billing.rs)
and [the consumer contract](GROK-CONSUMER-CONTRACT.md). That model explicitly
defaults a present empty `Cent` object to zero because proto3 JSON omits its
zero-valued scalar. Its amount is USD cents. Missing or null money is not the
same as a present empty object.

## App behavior

- Cursor keeps four stable choices: Cursor Models, Other Models, Grok Bot
  weekly, and on-demand spending. Provider values replace unavailable states;
  failed optional refreshes do not manufacture zero or erase primary usage.
- Reported `individualUsed` takes precedence over remaining allowance. Its
  signed 32-bit cents schema permits over-cap spend. Invalid reported spend
  cannot fall back to a fabricated value. Older responses without that field
  retain the existing limit-minus-remaining calculation.
- A finite positive cap produces the existing spending bar unless the provider
  explicitly disables spending. Missing, zero, negative and disabled caps keep
  valid reported spend in their unavailable explanation without an active meter.
  Zero cap means no spending allowance; a negative cap is invalid. A missing
  cap alone is not proof of unlimited spending. Disabled accounts use account
  status instead of stale per-metric response reasons. Valid spend-only responses
  still produce those choices when no active bar exists. A negative cap cannot
  manufacture legacy fallback spend.
- Cursor's Bot `usagePercent` is optional in the first-party schema. An absent
  or malformed percent stays unavailable. Explicit zero is a reported value.
  Team-pooled and absent included allowances retain their separate states.
- Existing saved visibility, width, order, ring style, history keys, account
  IDs, provider ownership, reset handling, and authorization remain unchanged.
- Direct Grok's omitted-usage convention still requires a verified paid plan,
  unified consumer billing, an active weekly period, and no reported usage.
  Its bar and explanation now identify that zero as inferred, not measured.
  Null, malformed, unsupported, or unverified usage does not qualify.
- Present empty Grok money means provider zero. Missing, null, or malformed
  money does not become zero and cannot erase independently valid weekly usage.

## Percentage and refresh parity

Verified October 3, 2026 EDT for [issue #400](https://github.com/HemSoft/codexbar-ios/issues/400).

The same installed first-party client carries `planUsage.autoPercentUsed` and
`apiPercentUsed` into its included-usage display. Its `VLo` and `B9h` helpers
use a displayed minimum of 1 for any positive percentage below 1. CodexBar now
applies that minimum to the two model categories and More Information. This is
presentation only: 0.1 remains 0.1 used out of 100, including History, fractions,
forecasts, widgets and Watch. Reported zero remains zero. Existing over-cap
values remain visible rather than being clipped to 100. Other providers and
Bot's existing percentage policy are unchanged.

The official client's response `enabled` flag controls its usage-message
visibility; `applyCurrentPeriodUsageResponse` still copies supplied plan values
when that flag is false. It is not evidence of zero or no included allowance.
CodexBar does not discard valid category values based on that display flag or
infer a missing split from aggregate spend. Both standard camel-case and
original protobuf snake-case category fields are accepted.

Usage requests are bearer-only, bypass local HTTP cache, and disable automatic
cookie handling. The default session is ephemeral with no cookie storage or
URL cache. This prevents a refresh from intentionally choosing a locally
cached response or adding another browser/account cookie. It does not prove
that HTTP cache or cookies caused the affected live snapshot's zero values.

The independent Bot read now has a five-second cancellable deadline and a
six-second transport backstop, with no retry. The later backstop lets the task
deadline own cancellation rather than race URLSession's timeout. A valid 2.5-second reply survives; the previous default
dropped it. Timeout, transport failure, invalid response, rejected session,
forbidden access and rate limiting retain distinct bounded explanations where
verified. Missing percent and explicit absent/team allowances retain the old
unavailable semantics. All four customization choices remain present even when
no numeric Bot bar can be built. A deliberately hidden metric stays hidden.

A read-only phone snapshot on October 3 at 8:42 PM EDT had two zero fractions
and no numeric Bot bar, versus Franz's reported 1%/3%. The source wire response,
identity and simultaneous billing context were not captured. A temporary,
opt-in whitelisted probe build installed, but iOS rejected launch because the
phone was locked. No credentials were exported, and the probe is removed from
the delivered source. Automated replays prove the app-side presentation,
request-policy and deadline corrections. They do not establish the particular
live response's cause. Franz owns the delivered build's live comparison.

Local regression command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --filter 'GrokAuthTests.Cursor'
```

New tests remain in the local-only SwiftPM target; automatic native test counts
and the five automatic jobs do not change. The Cursor UI journey is included
only in local or explicitly dispatched release validation.

## Validation boundary

Local regressions replay these first-party schemas with synthetic account data.
Manual simulator scenes use the actual production parsers in a UUID-namespaced,
network-blocked DEBUG environment. They are not live provider comparisons.
The original screenshot demonstrates the reference display, not the phone's
failing wire response. Franz owns the affected-account comparison after the
build is delivered. No new Groq integration, grant linking, purchases, manual
credential import, or automatic CI test expansion belongs to this change.

## Session renewal and reconnection

For [issue #402](https://github.com/HemSoft/codexbar-ios/issues/402), the same
first-party client checks the saved token's numeric JWT `exp` before use and
starts renewal within its 1,272-hour, 53-day lifetime window. It renews through `POST https://api2.cursor.sh/oauth/token`. Its JSON request uses
`grant_type: refresh_token`, the published public client ID and a refresh grant.
The response returns `access_token`, may return `refresh_token`, and can require
logout with `shouldLogout`. Without a rotated refresh token, the first-party
client uses the new access token as its next grant. No live credential was read
to inspect this contract.

CodexBar treats an ended numeric lifetime as a renewal hint, not authenticated
identity. Unsigned `sub` and other JWT identity claims are never used to choose
an account. With a saved refresh grant, the same early lifetime window and primary HTTP
401/403 can perform at most one renewal and one subsequent quota read. If early
renewal fails while the token remains unexpired, independently valid primary
usage can still succeed, including fresh zero. That attempt cannot be repeated
within the same refresh. Failed early grants back off for 15 minutes per account and credential
fingerprint; expiry still requires renewal immediately. An ended lifetime or primary rejection
requires browser recovery only if its single renewal cannot restore valid usage. A verified
`shouldLogout: true` renewal response also requires reconnection even when its HTTP
status is 200; it cannot fall back to zero quota from the old credential. Renewal requests
have a 15-second timeout, no cache or cookies, and the default session rejects
redirects. Keychain replacement is serialized with phone reconnection and only
occurs while the original account credential is still current. Canceled work
cannot rotate credentials or publish newly fetched usage.

When an ended or rejected session cannot be recovered with renewal, or renewed
credentials cannot be saved, a reconnect action is shown. It opens the existing private browser
sign-in from account Settings, without sign-out, credential import or OAuth
settings. Canceled sign-in leaves the saved account unchanged. Successful
browser replacement invalidates prior in-flight observations; a different or
unknown saved identity, including a missing previous secret, clears the previous account's history.
Known same-account reconnection preserves measured cache, history and saved metric choices while
invalidating prior in-flight work. Saved browser `authId` or `userId` supplies continuity. For
renewal without either identifier, the app preserves its existing cache fingerprint in the saved
credential. This fingerprint is not an account claim and never authorizes access.

Collection failures retain same-account measured values with their original
measurement timestamp and an explicit last-known-data warning, or show no
readings when none exist. Failed results are excluded from successful-refresh
History, forecasts and quota alerts. Widgets and Watch receive the same stale
status and measurement time. Bot-only authorization or transport failure does
not reject independently valid primary usage. A valid current 0% / 0% response
is still fresh zero and never triggers reconnection by itself.

The October 4 phone capture established HTTP 200 with explicit 0% / 0% at the
response boundary. Franz later reported that sign-out/sign-in restored usage,
and corrected the earlier comparison to 1% / 13%. Neither observation proves
expiration or an account switch. There is no independently verified marker for
an unusable yet unexpired or opaque credential returning a successful zero-only
response. This implementation does not invent one. Local regressions cover the
verified lifetime/rejection handling contract, not that earlier live mechanism.
Live renewal and quota parity remain pending Franz's account testing.
