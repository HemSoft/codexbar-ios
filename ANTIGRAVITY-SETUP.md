# Antigravity session import

Antigravity is a separate account type from Google Gemini in CodexBar. It tracks
the shared Gemini pool, including Flash, and the separate Claude/GPT pool. Each
has a five-hour and weekly metric. Gemini Apps history is never relabeled.

This experimental integration requires an imported desktop Antigravity session.
It does not offer Google sign-in directly on iPhone. Native sign-in and a final
connected-iPhone comparison are deferred for Franz's Mac follow-up, as authorized
on September 5, 2026 while implementing [#314](https://github.com/HemSoft/codexbar-ios/issues/314).
This is an unofficial API integration, not a Google-supported iPhone grant.

## Setup

1. Sign in to Antigravity on your desktop with the account whose quotas you want.
2. Obtain that account's exported session JSON through your desktop credential
   workflow. Upstream desktop CodexBar's OAuth flow stores portable credentials
   in `~/.codexbar/antigravity/oauth_creds.json`. An existing file can be copied
   to the Mac clipboard with `pbcopy < ~/.codexbar/antigravity/oauth_creds.json`.
   The Antigravity CLI stores its session in the OS keyring instead; CodexBar iOS
   does not export that keyring or provide a desktop export tool.
3. On iPhone, choose Settings, Add Account, Antigravity. Paste the session JSON
   into Antigravity Session Import and choose Save and Validate Session.
4. Refresh and compare both model families with Antigravity CLI `/usage` using
   the same account. The Gemini consumer website is a different product.

Never paste a session into chat, a GitHub issue, or a repository file. Clear the
clipboard after importing. Tokens may grant broader Google account access.
CodexBar stores only the supported credential fields in this account's Keychain
entry. Tokens do not enter History, widget snapshots, or Watch payloads.

The accepted flat JSON shape is:

```json
{
  "access_token": "<Antigravity access token>",
  "expiry": "2030-01-01T00:00:00Z"
}
```

The CLI profile shape `{"token":{"access_token":"...","expiry":"..."}}`
is also accepted. `expiry_date` may replace `expiry` when it contains Unix
milliseconds, as in upstream desktop CodexBar's export. Unknown fields are
discarded. Google website cookies and Gemini API keys are not session JSON.

Automatic renewal additionally requires `refresh_token`, `client_id`, and
`client_secret` from the same desktop OAuth client. For a nested CLI profile,
tokens and expiry belong inside `token`; client fields belong at the top level.
CodexBar does not guess or bundle another application's OAuth client. Without
all renewal fields, an expired or rejected token requires a fresh import.
Renewal uses Google's token endpoint and saves a rotated token only if the
account's imported credential has not changed or been removed during the request.
Renewal has fixture coverage; live renewal on iPhone remains unverified.

## Quota contract

The verified request is an authenticated JSON `POST` with body `{}` to:

```text
https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
```

The response contains `groups[].buckets[]`. The parser uses bucket IDs and
windows, not translated display names or model lists:

| Bucket | Window | CodexBar metric |
| --- | --- | --- |
| `gemini-5h` | `5h` | Gemini five-hour |
| `gemini-weekly` | `weekly` | Gemini weekly |
| `3p-5h` | `5h` | Claude/GPT five-hour |
| `3p-weekly` | `weekly` | Claude/GPT weekly |

Percent used is `100 * (1 - remainingFraction)`. Thus `0` remaining is 100%
used and `0.69` remaining is 31% used. Reset timestamps come only from supplied
`resetTime` fields. Missing, disabled, duplicate, out-of-range, or expired
buckets stay unavailable. Partial responses retain only proven current metrics
and identify the missing ones. A wholly unavailable response follows the app's
existing failure and stale-data presentation.

There is deliberately no fallback to `cloudcode-pa.googleapis.com`. A live
request on September 5 returned four all-full buckets there, while the CLI's
daily backend returned Gemini weekly `0.7202861` remaining, or 27.97139% used.
Supplying a project ID did not correct the other backend. The daily response
matched the CLI-local fractions and active Gemini weekly reset. Untouched
bucket resets advanced with request time and still need hands-on comparison.
See the [sanitized investigation receipt](https://github.com/HemSoft/codexbar-ios/issues/314#issuecomment-5555218152).

Requests reject redirects, disable automatic cookies and caching, and never
include raw server errors in user-facing messages. Quotas go only to the daily
backend; renewal credentials go only to `oauth2.googleapis.com/token`.

## Mac follow-up before release

- Verify import, renewal when client fields are available, and all four quotas
  on the connected iPhone against the same account's current `/usage`.
- Establish a supported native iPhone authorization path before adding an
  in-app sign-in button. Desktop success does not prove an iPhone grant.
- Exercise both exhausted and partial quotas. The earlier exhausted five-hour
  and approximately 31%-weekly report was no longer present during investigation.
