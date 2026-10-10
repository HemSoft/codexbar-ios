# Codex subscription names

The Codex card identifies the ChatGPT subscription independently of the account
nickname. Plan names come from the authenticated usage response's `plan_type`,
not from token claims, allowance sizes, spend or a user-entered plan choice.
The existing guided phone sign-in is sufficient; no additional lookup is made.

## Verified mappings

Verified against [OpenAI's protocol source](https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/protocol/src/auth.rs)
and [backend response schema](https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs)
on October 10, 2026. The current client deliberately distinguishes these three
Pro identifiers, as recorded in [the upstream naming change](https://github.com/openai/codex/pull/47971).

| Authenticated `plan_type` | Card pill |
| --- | --- |
| `prolite` | ChatGPT Pro |
| `pro` | ChatGPT Pro (More) |
| `promax` | ChatGPT Pro (Max) |
| `free`, `go`, `plus` | ChatGPT Free, Go or Plus |
| `business`, legacy `team` | ChatGPT Business |
| `enterprise`, `edu`, `health`, `gov` | ChatGPT Enterprise, Edu, Health or Gov |
| Missing, malformed or unrecognized | Plan unavailable |

Existing normalized identifiers remain stable, such as `codex.pro` and
`codex.prolite`. Display and accessibility text use natural casing, and the
existing card layout can wrap longer names while preserving independent controls.

## Numeric names and multipliers

[OpenAI's consumer subscription documentation](https://help.openai.com/en/articles/9793128-about-chatgpt-pro-tiers)
currently names the billing plans Pro 100, Pro 200 and Pro 500. That page does not
bind those numeric names to authenticated Codex identifiers. The first-party
Codex schema distinguishes the Pro tiers but contains no numeric billing name.
CodexBar therefore uses the verified Codex client names above rather than
claiming an unverified price variant.

[T3 Code's current resolver](https://github.com/pingdotgg/t3code/blob/dd4549eede928f9dc514778aeae15d74656a87f8/apps/server/src/provider/CodexProvider.ts#L115)
uses the same `planType` identifiers. It still labels `pro` and `prolite` with
historical 20x and 5x wording and `promax` as Pro Max.
[Desktop CodexBar's formatter](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/Providers/Codex/CodexPlanFormatting.swift)
also uses the historical multipliers. Those labels are not proof of an account's
current allowance, especially during grandfathering or provider changes.
Neither multiplier is added to the iOS pill.

The unauthenticated public pricing route rejected the research request with
HTTP 403. No numeric billing payload was obtained. Numeric names remain
unsupported until a first-party account-scoped source establishes their mapping;
users are not asked to export credentials or manually choose a tier.

## Refresh and isolation

Each usage response supplies the current plan. A successful response with an
unknown or malformed plan clears an earlier plan without discarding valid usage.
An optional reset-inventory request failing does not discard the usage or plan.

Publication checks the currently saved access token and account identity before
the request, after its response and after reset enrichment. A replaced or deleted
credential cancels the old result. Cached results are bound to a SHA-256 digest
of the credential's access token and authenticated account ID. Transient failures
can reuse that matching snapshot; authentication failures and missing or replaced
credentials cannot reuse it. The digest is internal cache metadata, not a plan
source. It contains no readable credential and is not exposed in the card.

## Validation

The local-only Codex SwiftPM tests cover mappings, unknown/malformed values,
refresh transitions, optional inventory failure, credential replacement, sign-out,
late responses and account isolation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter CodexUsageTests
```

The existing native pill journey uses isolated synthetic accounts and the
production Codex provider/parser with intercepted HTTP. It covers all three Pro
identifiers, Plus, unavailable data, custom titles, collapsed refresh upgrades,
light/dark appearance and default/accessibility text sizes on iPhone and iPad:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CodexBarIOS.xcodeproj -scheme CodexBarIOSUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:CodexBarIOSUITests/CodexCreditsPoolUITests/testPreciseSubscriptionPillsOnExpandedAndCollapsedCards test
```

These checks remain local or manual. Full release validation is unchanged.
Live account-to-provider subscription comparison belongs to Franz and remains
pending until he reports a result. Synthetic fixtures do not claim live access.
