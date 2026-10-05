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
Its activity fixture supplies hypothetical 12-of-50 credit-named metadata. With
no supported credit contract, that metadata must not become a quota or plan.
It checks dashboard copy, review statuses and account metrics, empty activity,
a hypothetical returned review quota, and provider failure. Its quota fixture
is deliberately 3 of 17 **reviews**, not an assumed real Free allowance.
The journey also forces the iPad simulator menu-relaunch workaround on both
families. That hook refreshes through the real provider before asserting sheet
content, rather than presenting a preconstructed or empty result.
Every other network request is blocked. See [UI testing](UI-TESTING.md) for the
focused command and release-only full-run guard.

## Remaining uncertainty

The live account's actual balance and billing boundaries were not verified.
Starter-specific trial transitions, overage behavior, tier availability and
undocumented runtime fields are not established by this investigation. The
safe current result is review activity plus an explicit unavailable billing
balance, not a fabricated approximation of the provider's allowance.

## Paid-plan follow-up, October 5, 2026

Research for [#397](https://github.com/HemSoft/codexbar-ios/issues/397).
The October 3 findings above remain a historical record. This follow-up checked
current first-party plan, billing, MCP, permissions and public API documentation
without accessing a paid account.

**A supported paid-plan code-review billing API is not verified.** The reviewed
sources do not establish an endpoint, tool, optional billing field or permission
that buying Pro or Enterprise unlocks. They also do not explicitly rule out
such an integration. Missing public documentation cannot establish that paid
plans never expose balances. The source ledger below records what was checked.

| Classification | Finding and evidence |
| --- | --- |
| Supported | [Pricing](https://www.greptile.com/pricing) documents Pro at $30 per seat per month, with 50 code-review credits per seat per month and $1 additional credits. Enterprise has custom pricing and includes Pro features. These are plan terms, not account consumption fields. |
| Supported | [Billing](https://www.greptile.com/docs/code-review-bot/billing-seats) documents per-developer included credits and flex usage, plus human-facing Usage and Billing dashboards. [Review tiers](https://www.greptile.com/docs/code-review/review-tiers) assigns Base 1 credit, Plus 3 and Apex 10. These billing rules do not supply an account balance API. |
| No explicit denial | No reviewed first-party source explicitly denies billing API access for all Pro or Enterprise subscriptions. No universal unsupported classification is justified. |
| Not verified | A supported read-only contract for consumed code-review credits, remaining allowance, plan eligibility or account billing-period/reset timestamps was not found in the reviewed [MCP reference](https://www.greptile.com/docs/mcp-v2/tools), [billing](https://www.greptile.com/docs/code-review-bot/billing-seats) or [plan documentation](https://www.greptile.com/pricing). Paid or negotiated Enterprise access remains unanswered. |

### Access and product boundaries

The [MCP setup guide](https://www.greptile.com/docs/mcp-v2/setup) documents OAuth
at `https://api.greptile.com/mcp`. The
[tools reference](https://www.greptile.com/docs/mcp-v2/tools) documents OAuth
organization selection and organization-bound API keys, plus review history,
account discovery and analytics. It does not document billing scopes or
paid-only balance fields. Its examples are not closed schemas.
[Organization settings](https://www.greptile.com/docs/account/organization-settings)
describes Enterprise custom roles, but does not identify a billing-read API
permission. This does not prove that changing roles or authentication reveals
a credit balance.

Code-review credits must remain distinct from any codebase-query or other API
allowance. The [current public documentation index](https://www.greptile.com/docs/llms.txt)
does not list a standalone codebase API contract. The former public
[query](https://www.greptile.com/docs/api-reference/query) and
[search](https://www.greptile.com/docs/api-reference/search) documentation URLs
redirected to the introduction; the
[repositories](https://www.greptile.com/docs/api-reference/repositories) and
[OpenAPI](https://www.greptile.com/docs/openapi.json) URLs redirected to a docs
login page rather than returning public API specifications. Those redirects
establish a research limitation, not API removal or paid-plan eligibility.
No login was attempted. No separate API unit, allowance, current billing schema
or relationship to code-review credits was verified. Do not import an API-query
quota into the code-review balance or rely on a third-party OpenAPI copy.

The [billing page](https://www.greptile.com/docs/code-review-bot/billing-seats)
describes credits per billing period and organization flex caps. It does not
provide this account's boundaries, reset timestamp or time zone, or an API
contract for them. An analytics date range remains a caller-selected range,
not an authoritative billing period.

### Source ledger

Every entry was checked on October 5, 2026. Conclusions apply to the published
material retrieved that day; there is no provider support confirmation.

| First-party source | Evidence checked | Checked |
| --- | --- | --- |
| [Pricing](https://www.greptile.com/pricing) | Starter, Pro and Enterprise terms; no advertised billing API entitlement | 2026-10-05 |
| [Billing](https://www.greptile.com/docs/code-review-bot/billing-seats) | Credit attribution, flex limits, Usage/Billing dashboards, support contact | 2026-10-05 |
| [Review tiers](https://www.greptile.com/docs/code-review/review-tiers) | Credit units vary by review tier | 2026-10-05 |
| [MCP tools](https://www.greptile.com/docs/mcp-v2/tools) | Account, review, knowledge-base and analytics contracts; no documented credit balance or reset tool | 2026-10-05 |
| [MCP setup](https://www.greptile.com/docs/mcp-v2/setup) | OAuth setup and tenant selection; no documented billing scope | 2026-10-05 |
| [Organization settings](https://www.greptile.com/docs/account/organization-settings) | Enterprise roles and review permissions; no documented billing-read API permission | 2026-10-05 |
| [Documentation index](https://www.greptile.com/docs/llms.txt) | Public documentation inventory; no standalone API specification listed | 2026-10-05 |
| [Query](https://www.greptile.com/docs/api-reference/query), [search](https://www.greptile.com/docs/api-reference/search) | Redirected to introduction | 2026-10-05 |
| [Repositories](https://www.greptile.com/docs/api-reference/repositories), [OpenAPI](https://www.greptile.com/docs/openapi.json) | Redirected to docs login; no public schema retrieved | 2026-10-05 |

### Provider questions and next step

The exact questions requiring Greptile confirmation are:

1. Does Pro, Enterprise or a negotiated deployment expose a supported read-only
   API or MCP tool for **code-review** credits consumed, included allowance,
   remaining credits and flex usage? What is its published, versioned contract?
2. Which plans and deployments qualify? Which OAuth scopes, API-key permissions
   and organization/user roles are required? Does the response describe the
   organization, an individual developer or unattributed usage?
3. What are the exact field names and units? How do tier charges, promotional
   credits and flex usage affect them, and are codebase API allowances separate?
4. Does it return authoritative period start/end and reset timestamps? What are
   the time zone, rollover, proration and reporting-delay semantics? Is fetching
   the data read-only and free of review charges or account changes?

The [billing documentation](https://www.greptile.com/docs/code-review-bot/billing-seats)
names support@greptile.com for billing questions and sales@greptile.com for
Enterprise pricing. No message was sent. Recommendation: preserve the current
review-history behavior; do not recommend purchasing a plan to enable CodexBar
credit tracking on this evidence. No supported implementation opportunity was
verified, so no billing-integration follow-up is proposed yet. If Greptile
supplies a supported contract, open a separate implementation issue before
changing transport, parsing or UI.

Paid-account runtime comparison remains **pending for Franz**, not an agent
delivery prerequisite. A later authorized read-only comparison should record
only redacted field names, units, scope and behavior against the same account's
dashboard. No upgrade, purchase, billable review, private-endpoint probe,
billing-session scrape or exported credential was used for this investigation.

### Compatibility check

Inspection of `makeReviewsRequest` and `reviewQuota(in:)` in
`CodexBarIOS/Services/GreptileUsageProvider.swift` confirms the request still
calls only `list_code_reviews`. Optional explicit review-named used/allowance
pairs retain their existing period fields and stable identity. Credit-named
metadata is not a review quota. The synthetic fixtures in
`GreptilePaginationTests/GreptileAllowanceRegressionTests.swift` exercise that
compatibility and missing-data behavior; they are not captures or proof of a
paid account's response. This research changes no integration, UI or CI work.
