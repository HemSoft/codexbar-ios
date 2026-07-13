# Changelog

Notable changes to CodexBar are documented here. Entries describe shipped app
behavior; development-only changes are listed separately when they affect
building, testing, or releasing the app.

## 1.1.0 - Unreleased

### Added

- Added complete Claude subscription usage details, including all-model and
  model-scoped weekly limits plus currency-aware usage-credit spending and
  monthly headroom shown alongside quota bars. ([#34](https://github.com/HemSoft/codexbar-ios/issues/34))
- Added installed version and build details to Settings, plus a quiet,
  dismissible notice and App Store link when a newer CodexBar release is
  available. ([#20](https://github.com/HemSoft/codexbar-ios/issues/20))
- Added persistent **Rate CodexBar** and **Get Support** actions in Settings,
  plus a restrained native rating request after sustained successful use.
  ([#19](https://github.com/HemSoft/codexbar-ios/issues/19))
- Added richer compact history graphs with latest value, change, range, and
  sample-window context on each usage card. ([#18](https://github.com/HemSoft/codexbar-ios/issues/18))
- Added a tappable expanded history view with a selectable native chart,
  labeled axes, summary statistics, and recent timestamped samples.
- Added account-scoped usage, balance, and severity alert details to each
  dashboard card, including the triggering value, configured threshold, and
  reset context where available. ([#17](https://github.com/HemSoft/codexbar-ios/issues/17))
- Added current-versus-projected context to severity alerts so projected limit
  pressure is distinguishable from current usage.
- Added account and alert-kind metadata to local notification payloads to
  support precise routing and future notification interactions.
- Added a debug alert-demo mode for repeatable visual checks in the simulator.

### Changed

- Made Cursor account switching deliberate and reliable: sign-in now uses a
  private browser session, sign-out clears stale identity labels, and an
  existing credential remains active until replacement sign-in succeeds.
  ([#35](https://github.com/HemSoft/codexbar-ios/issues/35))
- Kept ChatGPT / Codex and GitHub Copilot accounts signed in automatically
  instead of prompting users to reauthenticate unnecessarily, while showing
  clearer guidance when access is revoked or permissions are missing.
  ([#26](https://github.com/HemSoft/codexbar-ios/issues/26))
- Displayed reset, projection, history, and billing times in the user's current
  timezone and locale, including refreshed app and widget content after system
  time changes. ([#23](https://github.com/HemSoft/codexbar-ios/issues/23))
- Improved the App Store presentation with clearer screenshots, provider
  wording, privacy expectations, and a more scannable description for people
  evaluating CodexBar before install. ([#22](https://github.com/HemSoft/codexbar-ios/issues/22))
- Updated history presentation to handle empty, single-sample, flat, spiking,
  and balance data with dedicated scales and readable states.
- Updated alert notification titles and bodies to identify the affected account
  and condition more clearly.
- Updated dashboard status indicators to reflect the strongest active alert for
  each card, including user-configured thresholds below the default warning
  severity.
- Kept active alert details visible after notification deduplication, while
  continuing to suppress repeat notifications until the condition recovers.

### Fixed

- Kept the Codex 5-hour usage metric recognizable when ChatGPT reports a
  slightly varied window duration, while quietly showing only the available
  weekly limit when ChatGPT temporarily omits the 5-hour window.
  ([#38](https://github.com/HemSoft/codexbar-ios/issues/38))

### Developer Experience

- Added deterministic App Store screenshot capture automation for the six
  marketing scenes across iPhone 17 Pro Max and iPad Pro 13-inch (M5),
  including readiness polling, stable filenames, size checks, and Fastlane
  mirroring. ([#22](https://github.com/HemSoft/codexbar-ios/issues/22))
- Restored Swift 6 package-build compatibility for the main-actor notification
  service singleton.
- Added dedicated CodexBar signing-keychain reset and scoped-command helpers.
- Kept the lock-on-sleep signing keychain out of the normal macOS keychain
  search list, preventing unrelated system services from repeatedly requesting
  its password after wake.
- Documented the verified iPhone deployment and signing-recovery workflow in
  `AGENTS.md`.
- Established changelog maintenance rules so App Store release notes and
  marketing copy are derived from accurate, versioned product history.
- Added an automated Claude Code Review GitHub Actions workflow that reviews
  each pull request and posts inline findings, requiring the Claude GitHub App
  and an `ANTHROPIC_API_KEY` repository secret.
- Extended the Claude Code Review workflow to run on demand when `@claude` is
  mentioned in a pull-request or review comment, in addition to automatic runs
  on pull-request open and push.
