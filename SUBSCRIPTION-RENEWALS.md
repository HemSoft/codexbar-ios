# Subscription billing dates

Issue [#444](https://github.com/hemsoft-dev/codexbar-ios/issues/444) adds a compact
billing countdown and a default-on Dashboard preference. A quota reset, free
allowance refresh or projected billing-period boundary is not proof of a future
charge. The app never estimates renewal dates from plan names, prices or quotas.

## Current connection coverage

Source inspection on October 10, 2026 found these boundaries. Availability is
specific to the product and authentication method already connected in this app.

| Provider | Current evidence | Billing renewal support |
| --- | --- | --- |
| ChatGPT / Codex | `GET chatgpt.com/backend-api/subscriptions`, `active_until` plus Boolean `will_renew` | For verified individual Go, Plus and Pro plans, an optional request uses the existing account-bound OAuth grant, account query/header and Codex client identity headers. Business, Enterprise and unknown workspace plans lack a verified workspace billing contract and receive no lookup. A recognized 200 response supplies the date; rejected access or missing fields means unavailable. The inspected Codex Switch implementation reports successful OAuth reads with this request contract; native iOS transport/grant compatibility remains pending Franz's account check. |
| Claude | OAuth usage and profile provide reset windows and subscription tier | Unavailable through the current OAuth connection. The known billing route is `claude.ai/api/organizations/<uuid>/subscription_details`, using a web `sessionKey`. It needs verified web-account/organization ownership and `status`, `next_charge_at`/`next_charge_date`, `plan_ending_at`/`plan_ending_before`. Current OAuth does not expose that web credential. |
| Cursor | `GetCurrentPeriodUsage` exposes a usage period; `/auth/full_stripe_profile` supplies membership | No verified next-charge timestamp plus renewal/cancellation state in the supported response contract. `billingCycleEnd` remains a quota-period boundary, never a promised charge. |
| Copilot | Copilot quota windows | No per-subscription billing renewal and auto-renewal state in the connected quota response. |
| GitHub billing | Account or organization metered usage | Product usage and invoice periods do not identify an individual renewing subscription. No renewal pill. |
| Grok | Credit/weekly usage and separately verified tier | No verified next charge or auto-renewal state in the current APIs. Weekly quota dates remain usage resets. |
| Google Gemini | Code Assist tier metadata and Gemini usage windows | Google AI plan names do not supply Google One billing dates. Missing an account-bound next charge and renewal state. |
| Antigravity | Google coding quota windows | No directly identified recurring subscription or billing date in this connection. No renewal pill. |
| OpenCode Go / Zen | Go quotas and Zen credit balance | No verified next charge and cancellation state in the current console response. Month anchors used for projections do not establish renewal. A future verified date can appear independently of OpenCode's hidden plan pill. |
| OpenRouter | API credit balance | Prepaid/API credits, not a renewing subscription in this integration. No renewal pill. |
| Moonshot | API credit balance | Prepaid/API credits, not a Kimi subscription in this integration. No renewal pill. |
| Greptile | Free-credit allowance renewal | Existing allowance details stay separate. Free accounts get no billing-renewal pill. A paid subscription would need a verified next-charge/auto-renewal contract. |

Unavailable recurring products explain the missing billing date in **More
Information**. Confirmed free or prepaid products have no billing countdown.
Canceled subscriptions show their access end date in details and never say
"Renews". Nothing here requires users to import tokens, cookies or billing dates.

## Freshness and isolation

Billing observations are transient and bind both local account ID and provider.
ChatGPT requests use the current grant, reject redirects, disable shared cookies
and response caching, and have a three-second budget. The provider checks the
stored credential before and after the request. A returned account ID, when
present, must match the selected ChatGPT account. Access failures, malformed
responses, credential replacement and usage failures clear billing observations;
usage history never restores a previous date. No billing date enters persistent
history, widget or watch snapshots.

A successful observation is fresh for at most 24 hours. The pill updates every
minute and when the card renders after foregrounding, without fetching usage.
It floors full days and hours, then minutes with a minimum of one minute. It
never rolls a passed date into another month. Details retain a labeled last-known
or passed date until refresh replaces it. Date-only observations retain their
civil calendar day across time zones and DST, say "Renews today" on that day,
and disclose that the provider did not supply a charge time. Current ChatGPT
parsing requires an actual ISO-8601 timestamp.

Turning **Show subscription renewals** off hides header countdowns for all
accounts immediately and persists across launches. It does not hide exact
billing details or existing usage-reset dates. An absent saved preference defaults
to on for new installations and upgrades.

## Source evidence and remaining access work

The upstream CodexBar source was inspected at
[`6e118bd`](https://github.com/steipete/CodexBar/tree/6e118bdb5782707bfb0dfd0453d3483e3b216cd0).
Its [OpenAI response parser](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/OpenAIWeb/OpenAISubscriptionMetadata.swift)
uses `active_until` and `will_renew`; its
[dashboard fetcher](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/OpenAIWeb/OpenAIDashboardFetcher.swift)
uses browser cookies. The
[Claude billing client](https://github.com/steipete/CodexBar/blob/6e118bdb5782707bfb0dfd0453d3483e3b216cd0/Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeSubscriptionMetadata.swift)
requires a matching web session and organization, and prioritizes cancellation
end dates over residual next-charge fields.

The [Codex Switch request implementation](https://github.com/wen495033653/codex-switch/blob/2965a2e8d6d0737942e7e175951bb471d6816445/src-tauri/src/accounts/usage/client.rs)
and its [live verification notes](https://github.com/wen495033653/codex-switch/blob/2965a2e8d6d0737942e7e175951bb471d6816445/docs/development/subscription-refresh.md)
provide an OAuth acquisition avenue: account query/header, `OpenAI-Beta: codex-1`,
`Originator: Codex Desktop` and a `codex_cli_rs` compatibility user agent. The
notes also report HTTP/2 rejection with their Rust client and success over HTTP/1.1.
iOS uses URLSession protocol negotiation; no private protocol-forcing API or
claim of equivalent live transport behavior is used. Rejected native requests
remain unavailable. Live iOS access must still be checked before calling this
provider supported on Franz's account. If it rejects subscription access, a
public transport solution or guided, account-verified phone billing authorization
flow is still needed. Claude likewise needs a guided,
verified web-billing connection or an OAuth endpoint carrying billing fields.
Do not substitute Safari's inaccessible cookies, desktop imports, guessed dates
or a second account's billing session. Live date comparisons and OAuth billing
access verification remain pending for Franz; synthetic tests verify display,
isolation and failure handling, not access to a real subscription.
