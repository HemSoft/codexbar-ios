# Changelog

Notable changes to CodexBar are documented here. Entries describe shipped app
behavior; development-only changes are listed separately when they affect
building, testing, or releasing the app.

## 1.1.0 - Unreleased

### Added

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

- Updated history presentation to handle empty, single-sample, flat, spiking,
  and balance data with dedicated scales and readable states.
- Updated alert notification titles and bodies to identify the affected account
  and condition more clearly.
- Updated dashboard status indicators to reflect the strongest active alert for
  each card, including user-configured thresholds below the default warning
  severity.
- Kept active alert details visible after notification deduplication, while
  continuing to suppress repeat notifications until the condition recovers.

### Developer Experience

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
