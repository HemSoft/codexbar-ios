# CodexBar for iOS

Native iOS companion app for CodexBar. This repo starts from the Windows app's provider model and refresh-loop concepts, but uses SwiftUI and iOS-native storage, networking, and background behavior.

The Windows reference implementation is checked out beside this repo at:

```text
/Users/home/github/hemsoft/codexbar
```

## Current Scope

- SwiftUI dashboard for provider usage cards
- Provider abstraction with Codex, Copilot, Claude, Cursor, OpenRouter, OpenCode ZEN, and Moonshot (Kimi) adapters
- Settings screen for enabling providers, labeling accounts, choosing auth method, and saving API keys/tokens in Keychain
- ChatGPT / Codex browser sign-in with Keychain-backed usage fetching
- Refresh service with demo data for providers whose fetchers have not been ported yet
- Unit tests for model severity and refresh behavior

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
