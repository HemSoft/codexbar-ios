# CodexBar for iOS

Native iOS companion app for CodexBar. This repo starts from the Windows app's provider model and refresh-loop concepts, but uses SwiftUI and iOS-native storage, networking, and background behavior.

The Windows reference implementation is checked out beside this repo at:

```text
/Users/home/github/hemsoft/codexbar
```

## Current Scope

- SwiftUI dashboard with account-scoped usage cards for Codex, GitHub Copilot,
  Claude, Cursor, OpenRouter, OpenCode ZEN, and Moonshot (Kimi)
- Live provider adapters and settings for enabling accounts, choosing supported
  authentication methods, labeling accounts, and storing credentials in Keychain
- Usage history and charts, configurable usage alerts, and home-screen and
  lock-screen widgets
- Demo data limited to previews, smoke tests, widget galleries, and screenshots
- Simulator unit tests spanning configuration and authentication, provider
  parsing and networking, dashboard and settings, widgets, history, and alerts,
  plus a SwiftPM smoke harness; see [Build and Test](AGENTS.md#build-and-test)

## Requirements

- Xcode 16 or later
- iOS 17 or later

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

## Open Locally

```bash
open CodexBarIOS.xcodeproj
```

## Reference Repo

The current Windows app is a C# / WPF / .NET 9 system tray app with shared provider logic in `src/CodexBar.Core`. The iOS implementation should port behavior from there deliberately instead of sharing project structure directly.
