# Codex credits pool

Credits pool is an optional metric for a connected ChatGPT / Codex account.
It is off by default, including after an upgrade. Open Settings > Accounts &
Groups > the account > Metrics to turn it on. Customize Card uses the same
saved choice. Different accounts can make different choices; refreshing,
relaunching, renaming, and temporary missing data do not reset them.

The value is a remaining count of credits, not dollars, a percentage, a
subscription quota, or the number of banked usage resets. Existing quota bars
and reset actions keep their own identities and behavior. Reset Layout returns
the pool to its off-by-default state; an explicit Copy Layout can copy a saved
visibility choice. Other metrics retain their existing defaults.

## Read-only source

The existing authenticated `GET https://chatgpt.com/backend-api/wham/usage`
response carries an optional `credits` object. The same OAuth bearer and
`ChatGPT-Account-Id` already used for usage windows scope this value. No new
request, permission, sign-in step, credit purchase, billing change, or reset
consumption is added.

First-party source checked October 2, 2026, EDT:

- [Codex backend client usage route](https://github.com/openai/codex/blob/a20fe6335f960a350483d0079db2ec281c68202c/codex-rs/backend-client/src/client/rate_limit_resets.rs)
  reads the usage response from the ChatGPT `wham/usage` route.
- [Usage payload mapping](https://github.com/openai/codex/blob/a20fe6335f960a350483d0079db2ec281c68202c/codex-rs/backend-client/src/client.rs)
  maps `payload.credits` to the general Codex snapshot separately from quota
  windows, spend controls, additional model limits, and reset inventory.
- [CreditStatusDetails](https://github.com/openai/codex/blob/a20fe6335f960a350483d0079db2ec281c68202c/codex-rs/codex-backend-openapi-models/src/models/credit_status_details.rs)
  declares `has_credits` and `unlimited` booleans and an optional nullable string
  `balance`. The [app-server CreditsSnapshot](https://github.com/openai/codex/blob/a20fe6335f960a350483d0079db2ec281c68202c/codex-rs/app-server-protocol/schema/typescript/v2/CreditsSnapshot.ts)
  preserves those meanings.

This is a first-party client contract, not a published third-party API
stability guarantee. The credit object is optional and must not prevent normal
quota refreshes. Live same-account balance comparison remains pending for Franz.

## Value and visibility states

- A finite nonnegative reported balance displays a locale-formatted credit
  count, including zero. The app parses decimal strings without interpreting
  them as money. Synthetic `62500` displays `62,500 credits` in English-US.
- Valid numeric JSON balances are also accepted; booleans are not numbers.
  Malformed, missing, null, negative, and non-finite balances are unavailable,
  not fabricated zeroes. `has_credits` alone never supplies a number.
- An explicit unlimited status displays `Unlimited credits`, without creating
  a numeric zero, infinity, invented limit, or quota gauge.
- The Settings choice remains available when a value is absent. A failed
  refresh can retain the same account's last known value with existing stale
  status. A successful response without a balance shows unavailable instead
  of silently retaining an old current balance.
- Numeric values use the existing unbounded numeric presentation. They have
  no percentage, severity threshold, quota projection, or automatic balance
  alert. Watch visibility inherits the iPhone choice unless explicitly
  overridden. Independent saved widget selections are not removed by hiding
  the dashboard metric. Unlimited and unavailable Watch values remain text-only
  and follow the same visibility policy. Credit counts are excluded from quota
  history rather than shown as a made-up zero percent.

## Local validation

Twelve local-only Foundation regressions cover parsing, formatting, read-only
transport, account scoping, reset metadata, failed refresh, persisted defaults,
reordering, temporary absence, widget identity, and Watch visibility:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --filter CodexUsageTests
```

The focused manual native journey is
`CodexCreditsPoolUITests.testOptInBalanceStatesAndSavedAccountChoices`. Run it
on iPhone and iPad with the instructions in [UI-TESTING.md](UI-TESTING.md).
Synthetic screenshots and recordings are not proof of a live account balance.
