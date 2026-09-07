# CodexBar for iOS

Native iOS companion app for CodexBar. This repo starts from the Windows app's provider model and refresh-loop concepts, but uses SwiftUI and iOS-native storage, networking, and background behavior.

The Windows reference implementation is checked out beside this repo at:

```text
/Users/home/github/hemsoft/codexbar
```

## Current Scope

- SwiftUI dashboard with account-scoped usage cards for Codex, GitHub Copilot,
  Claude, Cursor, OpenRouter, OpenCode Go + Zen, Moonshot (Kimi), Greptile,
  and Google Gemini
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

## Google Gemini sign-in

One Gemini account contains all six Google usage metrics. Gemini Apps uses a
Google website session; Gemini Models and Other models use a separately imported
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
Google sign-in belongs to the same Google account before reconnecting. Add a
separate Gemini entry for another Google account. **Disconnect Gemini Apps**
removes this account's website session and preserves its coding session.
**Disconnect Coding Session** removes only coding authorization. Neither action
signs you out of Google in Safari or disconnects another CodexBar entry.

Open **Coding Usage** in the same Gemini settings to import your desktop coding
session JSON. Confirm that it belongs to this Gemini account, then choose
**Same Google Account**. Existing standalone coding accounts are retained and
can be linked here after that confirmation; CodexBar does not guess associations
from matching labels. All six metrics stay available in Metrics and Customize
Card even when a source needs setup. Their saved identities, layout, and history
survive the account consolidation. See [coding session setup](ANTIGRAVITY-SETUP.md)
for the supported import format and renewal requirements.

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
[coding session setup](ANTIGRAVITY-SETUP.md) for desktop import, renewal, and the
remaining live comparison checks.
