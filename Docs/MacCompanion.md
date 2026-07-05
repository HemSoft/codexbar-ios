# Mac Companion Exploration

## Recommended Path

Start with a Mac Catalyst companion scene before creating a separate native macOS target. Catalyst keeps the existing SwiftUI dashboard, provider configuration, keychain flows, app group snapshot format, and usage refresh services in one app bundle while still allowing a Mac-specific menu bar/popover surface.

Move to a separate native macOS app only if Catalyst blocks a required menu bar behavior, background refresh behavior, or signing/distribution requirement.

## Safe Shared Data

Safe to share:

- `ProviderAccountConfiguration` metadata, excluding stored secrets.
- `CodexBarWidgetSnapshot` provider/account usage snapshots.
- Usage history snapshots, because they store balances, percentages, labels, and timestamps but no API keys, cookies, or tokens.
- Dashboard grouping and manual ordering preferences.

Do not share directly:

- Raw API keys, OAuth payloads, browser session cookies, CLI tokens, or imported OpenCode ZEN dashboard credentials.
- Provider responses that have not been normalized into the app's non-secret usage models.

## Minimum Useful Menu Bar Experience

The first Mac companion should expose a menu bar extra that:

- Shows the most urgent provider/account in the menu bar title.
- Opens a compact popover listing all visible provider/account rows.
- Reuses `CodexBarWidgetSnapshot` as the data contract so the Mac UI can render without touching secrets.
- Opens the full CodexBar window for settings, credentials, grouping, and detailed history.

The prototype in this PR adds:

- `MacCompanionMenuSnapshot`, a platform-neutral summary built from `CodexBarWidgetSnapshot`.
- `MacCompanionPopoverView`, a compact SwiftUI popover layout for the future menu bar extra.

Dashboard smart ordering remains separate from this Mac companion work and belongs to issue #8.
