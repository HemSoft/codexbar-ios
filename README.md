# CodexBar for iOS

Native iOS companion app for CodexBar. This repo starts from the Windows app's provider model and refresh-loop concepts, but uses SwiftUI and iOS-native storage, networking, and background behavior.

The Windows reference implementation is checked out beside this repo at:

```text
/Users/home/github/hemsoft/codexbar
```

## Current Scope

- SwiftUI dashboard with account-scoped usage cards for Codex, GitHub Copilot,
  GitHub Billing, Claude, Grok, Cursor, OpenRouter, OpenCode Go + Zen, Moonshot
  (Kimi), Greptile, and Google Gemini
- Live provider adapters and settings for enabling accounts, choosing supported
  authentication methods, labeling accounts, and storing credentials in Keychain
- Usage history and charts, configurable usage alerts, and home-screen and
  lock-screen widgets
- Read-only Greptile review-activity tracking through an organization API key,
  with completed reviews kept distinct from pull requests and billing credits
- One Google Gemini account with six usage metrics for Gemini Apps, Gemini Models,
  and Other models, with separate five-hour and weekly limits for each source
- An embedded watchOS companion with a live, read-only dashboard that mirrors
  presentation-ready account metrics, visualization choices, ordering, and
  freshness from iPhone; provider setup, credentials, and provider networking
  remain iPhone-only
- Demo data limited to previews, smoke and isolated UI tests, widget galleries, and screenshots
- Simulator unit tests spanning configuration and authentication, provider
  parsing and networking, dashboard and settings, widgets, history, and alerts,
  plus watchOS foundation tests and a SwiftPM smoke harness; see
  [Build and Test](AGENTS.md#build-and-test) and the isolated iPhone/iPad
  [account UI journeys](UI-TESTING.md)
- A measured Release [usage-history performance budget](USAGE-HISTORY-PERFORMANCE.md)
  with retained-data limits and manual workflow runs

## Requirements

- Xcode 16 or later
- iOS 17 or later
- watchOS 10 or later for the companion app

## Local validation

For a local readiness audit, run
`./.agents/skills/perfection/scripts/run-perfection.sh`. Its seven gates cover
pinned repository-wide SwiftLint, complete strict concurrency, iOS build and
unit tests, SwiftPM smoke tests, and watchOS build and unit tests. Use `--list`
for gate names or `--status` for the most recent historical summary. See the
[perfection skill](.agents/skills/perfection/SKILL.md) for focused runs and the
separate UI and function-risk checks required by CI. Security analysis and the
performance budget run manually for relevant changes and release preparation;
see [security analysis](SECURITY-ANALYSIS.md) and
[performance verification](USAGE-HISTORY-PERFORMANCE.md).

The [CI policy](CI-POLICY.md) records measured runtimes, the five required
correctness checks, and manual security/performance dispatch and failure
ownership. Manual analysis keeps its existing failure rules and artifacts.

## OpenCode sign-in

OpenCode Go and Zen use system-browser approval with workspace selection.
Choose browser sign-in to allow an existing browser login, or private sign-in
to start a separate session. Google may still require identity verification.
No credential JSON or workspace-ID entry is required. See
[OpenCode sign-in](OPENCODE-SIGN-IN.md) for reconnection, local validation, and
pending live-provider checks.

## Grok sign-in

Grok consumer usage uses guided approval in a system browser. Choose the Grok
identity to monitor, approve the device request, and return to CodexBar. The
app verifies the identity and reads the shared usage period before securely
saving the account's token. Included usage, optional credit balance and
product breakdown are kept separate from Cursor Models and Grok Bot. Disconnect
removes only this device's saved credential. The Grok Build CLI client and
credits endpoint are first-party CLI contracts, not a published third-party
API; see [the provider contract](GROK-CONSUMER-CONTRACT.md). Live sign-in and
quota comparison are pending with the account owner.

## GitHub Copilot Sign-In

CodexBar bundles the public OAuth client ID and client secret used by
Copilot CLI-compatible clients. Static credentials shipped in an app cannot be
kept confidential: these values identify the OAuth application, but they do not
provide access to a GitHub account. Browser sign-in still requires the user to
authorize access, uses PKCE to protect the authorization-code exchange, and
stores the resulting account tokens in the iOS Keychain.

Developers can replace the bundled values in debug builds with the
`CODEXBAR_COPILOT_OAUTH_CLIENT_ID` and
`CODEXBAR_COPILOT_OAUTH_CLIENT_SECRET` environment variables. Release builds
ignore process-environment overrides and use values from the app bundle or the
documented defaults in `CopilotWebAuthService.swift`.

## GitHub Billing

GitHub Billing is a separate provider from GitHub Copilot. Choose
**Add Account → GitHub Billing → Sign in with GitHub**, review the requested
permissions, and select either your personal account or an organization where
you have billing access. Each monitored owner gets its own configuration and
Keychain credential; the integration never reads or replaces a Copilot token.

Personal Free and Pro cards show monthly allowance progress from GitHub's
[included-product table](https://docs.github.com/en/billing/reference/product-usage-included)
for eligible Actions minutes, Actions storage, Packages storage and data transfer,
Git LFS storage and bandwidth, and Codespaces compute and storage. Organization
Free and Team cards show the same account-scoped metrics except personal
Codespaces allowances. CodexBar requires GitHub's returned billing month to
contain the refresh time. Each verified metric states used, included, and
remaining usage, shows zero usage as 0%, and preserves overage above 100%.
Enterprise allowances stay unavailable because GitHub pools them above the
organization scope. The per-repository Actions cache allowance is not presented
as an account-wide bar.

Actions progress includes private-repository standard GitHub-hosted runners.
CodexBar normalizes each runner's usage to GitHub's Linux allowance-minute rate,
matching the Included usage figure in GitHub Billing. Returned unit prices must
match GitHub's current
[runner pricing table](https://docs.github.com/en/billing/reference/actions-runner-pricing)
before those minutes are accepted. Known paid larger runners from GitHub's
[SKU catalog](https://docs.github.com/en/billing/reference/product-and-sku-names#github-actions),
self-hosted runners, and public repositories are excluded from the hosted
standard-runner allowance. Standard-runner unit prices must match the current
pricing table exactly. Missing summary rows, hidden repository classifications,
unknown units, and unknown SKUs make only the affected metric unavailable. A
problem with one metric does not suppress
other verified allowances. Codespaces compute converts returned machine hours
with the documented core count in each `codespaces_compute_d*` SKU. Actions
storage converts GitHub's accrued GB-hours to the monthly GB figure shown in
GitHub Billing and includes only usage tied to repositories verified as private.
GitHub Billing does not identify
package visibility or whether transfer came from a free Actions download, so a
nonzero Packages storage or transfer quantity keeps that allowance unavailable;
a verified zero quantity can still show 0%. Each allowance also requires
returned gross, discounted, and billable quantities to be complete and
internally consistent. Evidence fails closed if GitHub reports billable covered
usage before the verified included allowance is exhausted.

Cards also show gross charges, discounts, net spend, and month-end projections.
Aggregate amounts use a complete, consistent ISO currency returned by GitHub;
when GitHub supplies no currency evidence, CodexBar uses GitHub's documented USD
billing currency. Partial, conflicting, or invalid currency evidence suppresses
monetary values instead of relabeling them. Metered usage groups into one
summary per product (Copilot, Actions, Codespaces, Packages, Git LFS, and any
other products GitHub returns) with consumed, discounted, and billable amounts
and quantities. Unit prices keep GitHub's source precision, for example
$0.006/minute, instead of rounding into a different rate.

Routine qualifications, including the lack of personal budgets and calculation
notes, live in the More Information sheet. Actionable problems such as
permission failures, incomplete billing data, and repositories that could not
be classified stay on the card. Organization cards keep allowance progress,
usage by product and SKU, monetary totals and projections, and returned
organization or repository budgets visibly separate. Other budget scopes remain
visible as unavailable because organization usage cannot establish their
consumption safely. Unsupported plans, missing API fields, unavailable billing
endpoints, permission failures, and rate limits remain visible instead of being
guessed.

The browser flow requests `repo admin:org user`, uses PKCE with a loopback
callback, and stores only the returned account token. Personal billing endpoints
require `user`, not the profile-only `read:user`, while GitHub requires
`admin:org` to include organization plan details. Existing users who authorized
the earlier scope must sign in again and approve the expanded permission.
The `user` scope also permits profile changes, reading private email addresses,
and following or unfollowing users. `admin:org` permits organization and team
changes. CodexBar never uses those additional capabilities. Classic GitHub OAuth
does not offer a private-repository metadata-only scope: `repo` permits
repository changes, while CodexBar limits its use to reading repository
visibility for billing classification. It limits `admin:org` to reading the
organization plan. GitHub supports separate
tokens per user, OAuth application, and scope combination, so the billing flow's
distinct scope combination and Keychain entry do not broaden or replace a saved
Copilot token even when both flows use the bundled public OAuth registration.
Billing administrators must grant access to organization billing data. Debug
builds can override the registration with
`CODEXBAR_GITHUB_BILLING_OAUTH_CLIENT_ID` and
`CODEXBAR_GITHUB_BILLING_OAUTH_CLIENT_SECRET`; release builds use the bundled
registration. Live account comparison remains an owner verification step.
Developers can run the synthetic API contract suite with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run GitHubBillingFixtureTests
```

## Google Gemini sign-in

One Gemini account contains all six Google usage metrics. Gemini Apps uses a
Google website session; Gemini Models and Other models use a separate
coding OAuth session inside the same account. Both connections are experimental.
See the verification boundaries in [Gemini sign-in evidence](GEMINI-SIGN-IN.md)
and [coding session setup](ANTIGRAVITY-SETUP.md).

Choose **Add Account → Google Gemini → Sign in with Google** and sign in to the
Google account you want to track. Each attempt opens a private website window
without reusing Safari or another CodexBar account's session. After sign-in,
CodexBar returns from Google Account to Gemini Usage automatically, verifies
both the five-hour and weekly meters with reset times, and saves the session
in that account's iOS Keychain entry. You can also use the window's **Back** and
**Gemini Usage** controls.

Use **Sign in Again with Google** to renew an expired session. Existing accounts
created by pasting credentials keep their saved session, label, group, history,
and display preferences. If a coding session is linked, confirm that the new
Google account selected in the browser belongs to the linked coding session
before the new session is saved. Add a
separate Gemini entry for another Google account. **Disconnect Gemini Apps**
removes this account's website session and preserves its coding session.
**Disconnect Coding Session** removes only coding authorization. Neither action
signs you out of Google in Safari or disconnects another CodexBar entry.

Open **Coding Usage → Connect Coding Usage** in the same Gemini settings.
Confirm that you will choose the same Google account, then complete browser
authorization. This flow requires the developer to configure a Google OAuth
iOS client before deployment; end users do not enter client settings. Existing standalone coding accounts are retained and
can be linked here after that confirmation; CodexBar does not guess associations
from matching labels. All six metrics stay available in Metrics and Customize
Card even when a source needs setup. Their saved identities, layout, and history
survive the account consolidation. See [coding session setup](ANTIGRAVITY-SETUP.md)
for developer configuration and renewal details.

Cancellation, a failed usage check, and a failed Keychain save leave the existing
credential unchanged. If Google denies access, cancel and retry with an eligible
account. If the sign-in page cannot load, check your connection and retry.

The integration uses ordinary Google website sign-in in a nonpersistent
`WKWebView` with its default user agent. It does not use a Google OAuth grant,
copy another application's OAuth registration, export Safari cookies, or require
a desktop CLI. Only secure `.google.com` root-path `__Secure-1PSID` and optional
`__Secure-1PSIDTS` cookies are retained. The app does not inspect page contents,
password fields, or JavaScript. Other website data exists only in the temporary
browser store and is discarded when that window closes.

Google session credentials are sensitive and may grant broader account access.
CodexBar uses the retained values only for read-only requests to
`gemini.google.com`, rejects cross-origin usage redirects, and never includes
them in diagnostics, settings, widgets, or Watch snapshots. This depends on an
undocumented consumer web contract. If Google changes or blocks it, sign-in or
refresh will report failure. See [Gemini sign-in evidence](GEMINI-SIGN-IN.md) for
the desktop reference, platform mechanism, and sanitized feasibility results.

## Open Locally

```bash
open CodexBarIOS.xcodeproj
```

The project includes shared `CodexBarWatch` and `CodexBarWatchTests` schemes.
The watch source is isolated under `CodexBarWatch/`; it intentionally does not
compile the iOS authentication, notification, widget, or UIKit-dependent code.
Use the documented simulator commands in
[Build and Test](AGENTS.md#build-and-test) to build and test the watch targets.

## Mutation Testing

A focused, non-blocking mutation-testing pilot covers deterministic dashboard
sorting and App Review prompt policy logic. See
[MUTATION-TESTING.md](MUTATION-TESTING.md) for the pinned tool, baseline
findings, survivor triage, and reproducible local command.

## Reference Repo

The current Windows app is a C# / WPF / .NET 9 system tray app with shared provider logic in `src/CodexBar.Core`. The iOS implementation should port behavior from there deliberately instead of sharing project structure directly.

## Gemini coding quotas

The Gemini account's Coding Usage connection reads Gemini Models and Other
models, Claude/GPT, from the internal Antigravity quota adapter. Each has
five-hour and weekly metrics alongside Gemini Apps on one dashboard card. See
[coding session setup](ANTIGRAVITY-SETUP.md) for browser setup, renewal, and the
remaining live comparison checks.
