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
- A finite positive cap produces the existing spending bar. A missing cap
  stays unavailable and preserves reported spend in its explanation. Zero cap
  means no spending allowance. A missing cap alone is not proof of unlimited
  spending. Explicit optional `enabled: false` identifies disabled spending.
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

## Validation boundary

Local regressions replay these first-party schemas with synthetic account data.
Manual simulator scenes use the actual production parsers in a UUID-namespaced,
network-blocked DEBUG environment. They are not live provider comparisons.
The original screenshot demonstrates the reference display, not the phone's
failing wire response. Franz owns the affected-account comparison after the
build is delivered. No new Groq integration, grant linking, purchases, manual
credential import, or automatic CI test expansion belongs to this change.
