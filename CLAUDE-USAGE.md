# Claude Usage Data Sources

CodexBar reads Claude subscription usage from:

```text
GET https://api.anthropic.com/api/oauth/usage
anthropic-beta: oauth-2025-04-20
```

This is an undocumented provider endpoint, so every field is decoded
defensively and optional values are omitted when absent or malformed.

## Display ownership

| CodexBar display | Provider field | Behavior when unavailable |
| --- | --- | --- |
| 5-hour percentage | `limits[kind=session].percent`, then `five_hour.utilization` | Omitted |
| 5-hour reset | `limits[kind=session].resets_at`, then `five_hour.resets_at` | `Starts when a message is sent` only when the provider reports zero percent with no reset |
| Weekly percentage/reset | `limits[kind=weekly_all]`, then `seven_day` or `seven_day_oauth_apps` | Omitted |
| Usage credits enabled | `spend.enabled`, then `extra_usage.is_enabled` | State is not inferred |
| Usage credits spent | `spend.used`, then `extra_usage.used_credits` | Omitted |
| Monthly spend limit | `spend.limit`, then `extra_usage.monthly_limit` | Omitted |
| Current balance | `spend.balance` | Omitted; never derived from the monthly limit |
| Remaining spend headroom | `spend.limit - spend.used`, then the equivalent `extra_usage` values | Labeled as derived and never presented as prepaid balance |
| Auto-reload | `spend.auto_reload` | Omitted if the key is absent |
| Spend reset | Not exposed in verified OAuth response shapes | Omitted |
| Promotional amount/expiry | Not exposed as a stable, provider-described OAuth field | Omitted |
| Temporary-limit notice | Not exposed as a stable, provider-described OAuth field | Omitted; codenames and plan labels are not interpreted as promotions |

## Window labels and plans

The shared session window is labeled "5-hour"; the all-model weekly allowance
is labeled "Weekly". Unified `5h` and `7d` rate-limit headers use the same
labels. Scoped limits retain their model names, and a shared session alongside
scoped sessions keeps its "Other models" qualifier. Metric keys and legacy
widget tile IDs do not depend on these new display labels.

Anthropic's [Max plan documentation](https://support.claude.com/en/articles/11049741-what-is-the-max-plan)
states that both Max tiers have a five-hour session reset and an all-model
weekly limit. The $200 tier increases the per-session allowance, not its
window length. Parsing follows the returned window kind rather than price or
plan name. Local synthetic Pro and Max 20x fixtures verify the labels and
unchanged percentages, resets, and saved identities. Live same-account Pro
and Max quota comparisons remain pending for Franz.

## Redacted regression shape

The regression test uses the same provider-owned money representation observed
in redacted 2026 OAuth responses:

```json
{
  "limits": [
    {"kind":"session","percent":0,"resets_at":null,"is_active":false},
    {"kind":"weekly_all","group":"weekly","percent":13,"resets_at":"2026-07-27T09:59:00Z","is_active":true}
  ],
  "spend": {
    "used": {"amount_minor":0,"currency":"USD","exponent":2},
    "limit": {"amount_minor":4000,"currency":"USD","exponent":2},
    "percent": 0,
    "enabled": true,
    "balance": {"amount_minor":10000,"currency":"USD","exponent":2},
    "auto_reload": null
  }
}
```

The dollar amounts mirror the issue's redacted first-party comparison target;
the fixture contains no session token, account identifier, cookie, request ID,
or organization ID. A release comparison must refresh CodexBar and Claude
Settings > Usage for the same authenticated account at the same time.

## Saved usage resets

Claude occasionally offers eligible subscriptions a limited number of saved
usage resets. Availability, affected windows and expiration are provider-owned;
a plan label is not evidence of a grant. See Anthropic's
[limit-reset explanation](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset).
A reset restores the allowance immediately without changing the normal weekly
schedule. Its use cannot be undone.

CodexBar reads the optional `cedar_ember` inventory by adding `cedar_ember=1`
to the usage request. Missing, malformed or unsupported inventory is unknown,
not a claimed zero balance. A confirmed empty eligible inventory is zero.
Counts exclude paused, expired and not-yet-started grants. Redemption is offered
only for the provider-selected `next_grant_id` when it is marked `usable_now`,
eligibility holds and any cooldown has ended. Other saved grants remain visible
with their availability and provider-reported expiration.

The reset sheet names the account, affected windows, expiration and irreversible
cost of one reset before confirmation. Cancelling confirmation sends no reset
request. Before a confirmed request, the client rereads inventory, verifies the
OAuth account and organization, and checks that the confirmation still belongs
to the exact saved credential. A changed account or rotated credential requires
a fresh usage read and a new confirmation.

The organization-bound `reset_rate_limits` POST uses `program=cedar_ember`, the
selected `grant_id` and a new `request_id`. This contract follows the
[current provider implementation](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/usage/claude-reset.ts),
not a stable published Anthropic API. The request identifies CodexBar honestly;
it does not impersonate another client to obtain reset eligibility. An unsupported
or ineligible provider response leaves redemption unavailable.

No mutation is retried automatically. Redirects are refused before a request can
be replayed or its grant data sent elsewhere. A changed fresh grant requires
new confirmation. Before the POST, an atomic app-private
receipt records only hashes of the provider account/organization and grant,
the remaining count and expiration. It is excluded from backup. Raw grant IDs,
credentials and inventory are not sent to widgets, Apple Watch, usage history,
configuration backups or diagnostics. A timeout, server failure or malformed
success retains the receipt across app restarts and token rotation. Another
POST is blocked until the same grant's fresh count changes or that grant
expires. An absent grant or unreadable receipt does not silently clear the
uncertainty. Every outcome refreshes authoritative usage and inventory;
only a confirmed provider outcome is presented as successful.

This supports saved Cedar grants; the separate Juniper session-reset experiment
is not interpreted as a saved grant. Automated validation uses synthetic data
and blocked networking. Live account eligibility and before/after comparisons
remain pending for Franz.
