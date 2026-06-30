# CodexBar for iOS

Native iOS companion app for CodexBar. This repo starts from the Windows app's provider model and refresh-loop concepts, but uses SwiftUI and iOS-native storage, networking, and background behavior.

The Windows reference implementation is checked out beside this repo at:

```text
/Users/home/github/hemsoft/codexbar
```

## Current Scope

- SwiftUI dashboard for provider usage cards
- Provider abstraction ready for Codex, Copilot, Claude, OpenRouter, and Cursor adapters
- Settings screen for enabling providers, labeling accounts, choosing auth method, and saving API keys/tokens in Keychain
- ChatGPT / Codex usage fetcher using pasted Codex CLI `auth.json` contents or access token
- Refresh service with demo data for providers whose fetchers have not been ported yet
- Unit tests for model severity and refresh behavior

## Requirements

- Xcode 16 or later
- iOS 17 or later

## Open Locally

```bash
open CodexBarIOS.xcodeproj
```

## Reference Repo

The current Windows app is a C# / WPF / .NET 9 system tray app with shared provider logic in `src/CodexBar.Core`. The iOS implementation should port behavior from there deliberately instead of sharing project structure directly.
