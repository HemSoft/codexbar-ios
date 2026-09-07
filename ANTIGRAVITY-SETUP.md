# Gemini coding session import

One Google Gemini account contains all six usage metrics in CodexBar. Its
Gemini Apps connection uses Google website cookies. Its Coding Usage connection
uses an imported desktop OAuth session to read Gemini Models and Other models,
Claude/GPT. The two credential formats are separate and are never substituted
for each other. Antigravity is an internal quota adapter, not a separate account
choice or dashboard card.

This experimental coding integration requires a desktop session import. Native
iPhone coding authorization is not available. It uses an unofficial Google API.
Franz's live comparisons remain follow-up verification for
[#319](https://github.com/HemSoft/codexbar-ios/issues/319) and do not block agent
implementation or merge.

## Six metrics in one Gemini card

| Source | Metric label | Preserved identity |
| --- | --- | --- |
| Gemini Apps | Gemini Apps five-hour | `gemini.five-hour` |
| Gemini Apps | Gemini Apps weekly | `gemini.weekly` |
| Coding session | Gemini Models five-hour | `antigravity.gemini-5h` |
| Coding session | Gemini Models weekly | `antigravity.gemini-weekly` |
| Coding session | Other models five-hour | `antigravity.3p-5h` |
| Coding session | Other models weekly | `antigravity.3p-weekly` |

All six choices appear together in Gemini's Metrics settings and Customize
Card. Hide, order, width, and visualization preferences survive refresh and
relaunch. Missing connections show Setup required without invented percentages
or resets. Missing or disabled quotas retain their actual status. History,
widgets, and Watch preserve source identities and contain only observed values.

Existing standalone coding accounts remain stored until you link them from
Gemini settings. Confirm that both sessions belong to the same Google account.
Matching labels do not prove identity, and CodexBar does not guess an association.
Confirmed linking transfers coding credentials and metric preferences into the
chosen Gemini account and preserves its observed history. Unlinked records stay
retained internally. Old source setup cards disappear; saved choices are retained
when their Gemini account can be identified.

## Setup

1. Sign in to Antigravity on your desktop with the account whose quotas you want.
2. Obtain that account's exported session JSON through your desktop credential
   workflow. Upstream desktop CodexBar's OAuth flow stores portable credentials
   in `~/.codexbar/antigravity/oauth_creds.json`. An existing file can be copied
   to the Mac clipboard with `pbcopy < ~/.codexbar/antigravity/oauth_creds.json`.
   The Antigravity CLI stores its session in the OS keyring instead; CodexBar iOS
   does not export that keyring or provide a desktop export tool.
3. On iPhone, add or open the Google Gemini account for that Google identity.
   In Coding Usage, paste the session JSON and choose Connect Coding Session.
   Confirm the sessions belong to the same Google account. Use Update Coding
   Session to replace an expired token after the same confirmation.
4. To reuse an existing saved coding account, choose its Link saved coding
   account action inside Gemini settings and confirm the same identity.
   Disconnect an existing coding session before linking a different saved one.
5. Refresh the Gemini card and compare both coding model families with
   Antigravity CLI `/usage` using the same account. Gemini Apps is a different
   quota source on that same card.

Reconnecting Gemini Apps while coding is linked requires confirmation that you
will sign in to the same Google account. Add another Gemini entry for a different
identity. Disconnect Gemini Apps and Disconnect Coding Session remove only their
respective authorization; the other source stays connected.

Never paste a session into chat, a GitHub issue, or a repository file. Clear the
clipboard after importing. Tokens may grant broader Google account access.
CodexBar stores only the supported credential fields in this account's Keychain
coding entry, separate from Gemini Apps cookies. Tokens do not enter History,
widget snapshots, or Watch payloads.

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
| `gemini-5h` | `5h` | Gemini Models five-hour |
| `gemini-weekly` | `weekly` | Gemini Models weekly |
| `3p-5h` | `5h` | Other models five-hour |
| `3p-weekly` | `weekly` | Other models weekly |

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

## Live verification follow-up for issue #319

The September 5, 2026 baseline inspection found CodexBar 1.3 build 3 on the
connected iPhone 17 Pro Max running iOS 27.0, build 24A5418b. Its saved account
configuration included Google Gemini and no Antigravity account. Gemini Apps
showed 0% five-hour and 1% weekly usage on both the phone and the desktop Usage
limits page. The displayed resets were 11:44 p.m. EDT and September 8 at
7:44 p.m. EDT, respectively. The installed app's source commit is unknown.

On September 6, the PR app was installed and launched on the same phone.
Mirroring verified all four coding visibility switches and their persistence.
The two live Gemini Apps values still matched the consumer reference; their
visibility, order, width and visualization changes survived relaunch and the
original layout was restored. No Antigravity credential has been imported.

Franz took ownership of the remaining live iPhone testing on September 6 and
directed that it no longer block PR #320. He reported Gemini Models weekly at
71% remaining and the other three coding buckets at 100% remaining. These are
reference values, not a successful phone fetch. Coding values and reset parity,
import/reimport and combined-card customization remain his follow-up checks in
[#319](https://github.com/HemSoft/codexbar-ios/issues/319). They are not claimed
as passed and do not block delivery of the unified account.

Franz can use these optional checks after receiving the updated build:

1. Unlock the phone and use a signed-in CLI session for the same Google account.
   Record `agy --version`, interactive `/usage`, and
   `agy -p "/usage" --output-format json`. Do not publish identity or tokens.
2. Complete session export and import, then follow `DEVICE-DEPLOYMENT.md` to
   build, install and launch the PR commit on the rediscovered device.
3. Refresh both sources in the same comparison interval. Record used versus
   remaining semantics, values and supplied resets for all six metrics.
4. Toggle and customize each choice, relaunch, then hide or disconnect Apps
   and verify all four coding metrics remain in the same Gemini card. Keep before/after screenshots locally
   and publish only evidence without identity or credentials.
5. Record renewal if matching client fields are available, or exercise and
   document reimport. Saving a credential without a successful quota refresh
   does not prove access.

A native iPhone authorization flow remains separate work. Verify an appropriate
Google iOS grant before adding a sign-in button; desktop success alone does not
establish that grant.
