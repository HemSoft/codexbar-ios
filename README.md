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
- Read-only consumer Gemini Apps usage tracking through Google website sign-in, with separate 5-hour and weekly meters and reset times
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

## Requirements

- Xcode 16 or later
- iOS 17 or later
- watchOS 10 or later for the companion app

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

This experimental website integration is implemented for testing. The earlier
simulator probe verified consumer usage, but production live sign-in, account
switching, and reconnect on a connected iPhone remain a pre-release gate. The
steps below describe the intended workflow; see the current verification
boundaries in [Gemini sign-in evidence](GEMINI-SIGN-IN.md).

Choose **Add Account → Google Gemini → Sign in with Google** and sign in to the
Google account you want to track. Each attempt opens a private website window
without reusing Safari or another CodexBar account's session. After sign-in,
CodexBar returns from Google Account to Gemini Usage automatically, verifies
both the five-hour and weekly meters with reset times, and saves the session
in that account's iOS Keychain entry. You can also use the window's **Back** and
**Gemini Usage** controls.

Use **Sign in Again with Google** to renew an expired session. Existing accounts
created by pasting credentials keep their saved session, label, group, history,
and display preferences. Reconnecting replaces only their credential. Add a
separate Gemini entry for another Google account. **Disconnect Google Account**
removes only the selected entry's saved session and does not sign you out of
Google in Safari or disconnect another CodexBar entry.

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

## Antigravity quotas

Antigravity session import tracks separate Gemini and Claude/GPT five-hour and
weekly quotas. It does not replace Google Gemini Apps accounts. See
[Antigravity setup](ANTIGRAVITY-SETUP.md) for the experimental import flow, token
renewal requirements, and deferred connected-iPhone validation.
