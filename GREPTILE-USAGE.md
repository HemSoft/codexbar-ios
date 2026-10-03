# Greptile review activity and billing allowance

Investigation for [#395](https://github.com/HemSoft/codexbar-ios/issues/395),
checked October 3, 2026. Sources below are first-party public documentation,
not a capture of Franz's account. No account credentials or private review
history were accessed, and no review, upgrade or billing action was triggered.

## Conclusion

Greptile's [pricing page](https://www.greptile.com/pricing) lists Starter as
Free with **50 credits per month**, one active developer and unlimited
repositories. That entitlement is real public product information. It is not
an account-specific used or remaining balance.

The [published MCP tools](https://www.greptile.com/docs/mcp-v2/tools) do not
document an allowance, remaining-credit balance or billing-period reset tool.
The app currently calls `list_code_reviews`, whose documented response contains
review activity, not billing usage. Consequently, the app cannot establish
Franz's remaining Free allowance from that published response contract.

This does **not** prove that Greptile has no private billing endpoint or never
returns optional billing fields. The reference provides examples and prose,
not exhaustive closed schemas. We did not probe private endpoints or inspect
an authenticated account response. A new supported billing API would require
its own verified contract before integration.

The app now explains that the connection shows review history rather than
remaining credits. Empty activity with no billing fields is unavailable
billing data, not a zero balance. Existing explicit returned review quotas
remain supported without changing numeric identity, values or reset dates.

## Credits are not a count of PRs

According to [Billing](https://www.greptile.com/docs/code-review-bot/billing-seats)
and [Review tiers](https://www.greptile.com/docs/code-review/review-tiers):

- Base costs 1 credit, Plus 3 and Apex 10. Billing separately lists T-Rex
  reviews at 3 credits. Fifty credits therefore do not guarantee fifty reviews
  at every tier. Whether each tier is available on a particular Starter
  account was not verified.
- Completed review runs count toward billing, not unique PRs. Skipped reviews
  do not count. Multiple completed runs on the same PR can incur multiple
  charges, including automatically triggered runs.
- PR reviews are charged to the PR author, not the person who triggered them.
  Included credits and flex usage are per developer, not a shared team pool.
- Attributed CLI reviews share the user's seat allowance. Unattributed CLI
  reviews are flex usage. API-key reviews are unattributed unless the key is
  bound to a user with a linked account.

The pricing page says "per month" and billing documentation says "per billing
period." Neither source supplies this account's current period, reset date,
time zone, rollover or proration. Do not assume a first-of-month reset or
subtract all-history completed reviews from 50.

## What the documented tools establish

| Source/tool | What it supplies | What is not documented |
| --- | --- | --- |
| `list_code_reviews`, `get_code_review` | Review IDs, statuses, timestamps, PR information and progress metadata | Charged credits, actual allowance, remaining credits, billing-period reset |
| `get_me` | Credential principal, reachable organizations and roles | Plan entitlement or credit balance |
| Analytics tools | Review/findings metrics, selected time ranges, rankings and repository/author filters | Billing balance, entitlement or authoritative billing-period boundaries |

All three rows are from the
[Tools Reference](https://www.greptile.com/docs/mcp-v2/tools). Review strictness
metadata is not a credit price. An analytics date filter is not proof of a
billing period. Repository visibility may also restrict activity counts.

The reference states that an API key is bound to its own organization and
ignores OAuth tenant arguments/headers. It does not document an additional
billing-allowance scope for these tools. Changing account selection or adding
permissions cannot be promised to reveal fields absent from the published
contract. Authentication failures remain distinct from a successful response
that lacks billing data.

## App contract and compatibility

`CodexBarIOS/Services/GreptileUsageProvider.swift` makes a read-only
`list_code_reviews` tools call through `https://api.greptile.com/mcp`. This HTTP
POST is JSON-RPC transport, not a request to trigger a review.

- Complete, deduplicated review activity remains labeled **Completed reviews**
  under **All available review history**. Missing billing data never creates a
  50-credit gauge, a dollar balance, a Free badge or a guessed reset.
- Optional explicit `reviewsUsed` plus positive `includedReviews` or equivalent
  review-named fields still produce **Reviews used** for **Current billing
  period**. This is compatibility behavior, not a claim that the published
  MCP schema includes those fields or that they measure credits.
- Credit-named fields are not silently treated as review counts. Malformed,
  Boolean or non-positive allowance values cannot create a quota.
- Existing stable keys, account-scoped credentials, saved metric/widget/Watch
  choices and pagination/truncation limits remain unchanged.
- Provider/authentication errors remain errors. Successful missing billing data
  is not evidence of a rejected key and does not call for repeated sign-in.

[Usage](https://app.greptile.com/-/settings/usage) and
[Billing](https://app.greptile.com/-/settings/billing) are the provider's documented
human-facing account views. The documentation does not turn these web pages
into a supported API. Do not scrape sessions, export browser credentials,
require manual balances, trigger paid reviews or buy a plan to validate this
integration. Live same-account comparison remains with Franz; it is not an
agent delivery prerequisite.

## Reproducing the investigation

Run the local-only regression target:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --filter GreptilePaginationTests
```

`GreptileAllowanceRegressionTests` drives the production provider through an
isolated URL protocol. It covers activity without billing fields, empty
activity, credit-looking/malformed metadata, explicit returned review quota
and reset, and authorization failure. The first two clarity assertions failed
against the original messages before the fix. Existing pagination regressions
remain in the same local-only target; automatic native test counts are unchanged.

The manual `GreptileAllowanceUITests` journey drives the same production
transport/parser through an intercepted synthetic endpoint on iPhone and iPad.
It checks dashboard copy, review statuses and account metrics, empty activity,
a hypothetical returned review quota, and provider failure. Its quota fixture
is deliberately 3 of 17 **reviews**, not an assumed real Free allowance.
Every other network request is blocked. See [UI testing](UI-TESTING.md) for the
focused command and release-only full-run guard.

## Remaining uncertainty

The live account's actual balance and billing boundaries were not verified.
Starter-specific trial transitions, overage behavior, tier availability and
undocumented runtime fields are not established by this investigation. The
safe current result is review activity plus an explicit unavailable billing
balance, not a fabricated approximation of the provider's allowance.
