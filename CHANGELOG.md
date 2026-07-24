# Changelog

Notable changes to CodexBar are documented here. Entries describe shipped app
behavior; development-only changes are listed separately when they affect
building, testing, or releasing the app.

## 1.2.0 - Unreleased

### Added

- Added a live, read-only Apple Watch dashboard that mirrors iPhone account
  metrics, visualization choices, ordering, and freshness while keeping the
  last valid snapshot available when the devices disconnect.
  ([#104](https://github.com/HemSoft/codexbar-ios/issues/104))
- Added per-metric dashboard and widget visualization choices with Automatic,
  linear, segmented, ring, dial, and large-number styles that persist separately
  for each configured account. ([#103](https://github.com/HemSoft/codexbar-ios/issues/103))
- Added a discreet banked Codex reset count beside usage limits and a confirmed,
  account-scoped action to use one reset when ChatGPT verifies redemption is
  supported. ([#84](https://github.com/HemSoft/codexbar-ios/issues/84))
- Added per-tile widget links that open CodexBar at the matching provider
  account on the dashboard. ([#63](https://github.com/HemSoft/codexbar-ios/issues/63))
- Added Moonshot (Kimi) as a new provider: paste an API key from
  platform.kimi.ai to track the available credit balance on the dashboard, in
  history, and in widgets, alongside the existing OpenRouter and OpenCode ZEN
  balances. ([#66](https://github.com/HemSoft/codexbar-ios/issues/66))

### Changed

- Let users open a native inventory from the Codex card, inspect each saved
  reset and its localized expiration, and explicitly choose which reset to use.
  ([#101](https://github.com/HemSoft/codexbar-ios/issues/101))
- Restricted browser sign-in callbacks to this device, matched callback hosts
  to each provider's requirements, and made stalled ChatGPT, Claude, and GitHub
  Copilot sign-ins time out cleanly. ([#52](https://github.com/HemSoft/codexbar-ios/issues/52))

### Fixed

- Hid redundant usage-threshold alert text on Codex dashboard cards while
  preserving threshold notifications and other alert types. ([#94](https://github.com/HemSoft/codexbar-ios/issues/94))
- Made ChatGPT, Claude, and GitHub Copilot browser sign-in callbacks reliable
  when the browser delivers the local HTTP request in multiple pieces.
  ([#87](https://github.com/HemSoft/codexbar-ios/issues/87))
- Kept accounts and their dashboard, history, and widget state available when
  Keychain credential deletion fails so removal can be retried safely.
  ([#86](https://github.com/HemSoft/codexbar-ios/issues/86))
- Kept server-provided details out of GitHub Copilot sign-in errors while
  preserving a safe OAuth error identifier for troubleshooting.
  ([#70](https://github.com/HemSoft/codexbar-ios/issues/70))
- Reported corrupt Keychain credentials and usage-history persistence failures
  instead of treating them as missing or silently discarding history changes.
  ([#65](https://github.com/HemSoft/codexbar-ios/issues/65))
- Show representative sample data in the widget gallery instead of loading the
  current account snapshot while users preview widget configurations.
  ([#62](https://github.com/HemSoft/codexbar-ios/issues/62))
- Kept pending provider-setting edits from overwriting newer Cursor sign-in,
  sign-out, or OpenCode credential changes. ([#61](https://github.com/HemSoft/codexbar-ios/issues/61))
- Reported credential-storage failures instead of presenting unsuccessful
  provider sign-ins or credential changes as complete. ([#61](https://github.com/HemSoft/codexbar-ios/issues/61))
- Kept provider cards, widgets, and cached usage visible and ordered consistently
  when refreshes fail, queued one follow-up refresh when new triggers arrive
  during an active refresh, and surfaced credential-read errors instead of
  treating them as a missing account.
  ([#60](https://github.com/HemSoft/codexbar-ios/issues/60))
- Stopped routine Claude usage refreshes from sending a billable Messages API
  request when subscription usage is unavailable or incomplete, while keeping
  previously displayed rate-limit windows visible when available.
  ([#58](https://github.com/HemSoft/codexbar-ios/issues/58))
- Preserved Copilot balance, monetary usage, and status details when applying
  configured account labels. ([#57](https://github.com/HemSoft/codexbar-ios/issues/57))
- Kept a newer Claude sign-in from being overwritten when an older token
  refresh finishes at the same time. ([#56](https://github.com/HemSoft/codexbar-ios/issues/56))
- Kept sensitive authorization details out of Claude and Cursor sign-in error
  messages while preserving the HTTP status and safe OAuth error identifier
  needed to understand failures. ([#53](https://github.com/HemSoft/codexbar-ios/issues/53))
- Protected temporary OpenCode ZEN bootstrap credentials before reading them
  and continued removing the staging file after every import attempt.
  ([#54](https://github.com/HemSoft/codexbar-ios/issues/54))

### Developer Experience

- Added pull-request and `main` branch CI coverage for iOS unit tests, watchOS
  unit tests, and the SwiftPM smoke harness using simulator destinations
  discovered from each runner. ([#107](https://github.com/HemSoft/codexbar-ios/issues/107))
- Added an embedded watchOS 10 companion target, shared watch app and test
  schemes, a deterministic accessible SwiftUI shell, and simulator-tested watch
  foundation coverage. ([#96](https://github.com/HemSoft/codexbar-ios/issues/96))
- Added deterministic unit coverage for the production widget configuration,
  timeline, entity-query, filtering, and tile-selection logic. ([#97](https://github.com/HemSoft/codexbar-ios/issues/97))
- Added required privacy manifests to the app and widget bundles, including a
  build-time regression check, so App Store submissions declare local and
  app-group preference access correctly. ([#85](https://github.com/HemSoft/codexbar-ios/issues/85))
- Made the simulator runner follow Xcode's latest selected runtime and device,
  hoisted repeated settings formatting work, and removed obsolete
  authentication and parsing code.
  ([#65](https://github.com/HemSoft/codexbar-ios/issues/65))
- Split the monolithic test suite into domain-focused classes with isolated
  network and preference fixtures so independent test groups can run in
  parallel without sharing mutable state.
  ([#64](https://github.com/HemSoft/codexbar-ios/issues/64))
- Split widget configuration, views, accessory layouts, and tile models into
  focused files, and shared provider logos, progress bars, severity colors, and
  currency formatting between the app and widget.
  ([#62](https://github.com/HemSoft/codexbar-ios/issues/62))
- Moved dashboard refresh, alert, widget-sync, ordering, and provider sign-in
  orchestration out of SwiftUI views so those flows can evolve and be tested
  independently. ([#61](https://github.com/HemSoft/codexbar-ios/issues/61))
- Consolidated shared provider credential renewal, loopback browser callbacks,
  form encoding, and pasted-secret normalization so authentication fixes can be
  applied consistently across providers. ([#59](https://github.com/HemSoft/codexbar-ios/issues/59))
- Documented why the public GitHub Copilot OAuth application credentials are
  bundled, how PKCE protects sign-in, and limited process-environment credential
  overrides to debug builds. ([#55](https://github.com/HemSoft/codexbar-ios/issues/55))
- Clarified agent guidance for builds, tests, automated PR reviews, iPhone
  deployment, signing recovery, and browser authentication.
- Documented the SwiftPM smoke-test command and kept its provider-coverage check
  aligned with the current seven-provider demo data.

## 1.1.0 - 2026-07-15

### Added

- Added pace-based usage predictions to Cursor's included, Auto, API, and
  on-demand metrics so users can see whether each billing-cycle limit is likely
  to be reached early. ([#46](https://github.com/HemSoft/codexbar-ios/issues/46))
- Added a per-account **Show History** setting so each provider card can hide
  its History section without discarding collected samples. ([#41](https://github.com/HemSoft/codexbar-ios/issues/41))
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

- Kept configured provider cards visible as soon as CodexBar opens, with per-account
  loading, cached-data refresh, failure, and retry states while current usage
  arrives. ([#49](https://github.com/HemSoft/codexbar-ios/issues/49))
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

- Preserved Claude's shared 5-hour session, all-models weekly allowance, and
  model-scoped weekly allowances such as Fable as distinct usage bars with
  their own values, reset times, projections, history, widget entries, and
  alerts, while keeping existing weekly alerts and saved widget tiles intact
  across the upgrade. ([#43](https://github.com/HemSoft/codexbar-ios/issues/43))
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
- Removed the Claude reviewer GitHub Actions workflow after upstream failures
  made it an unreliable merge-readiness signal; Codex and CodeRabbit remain the
  primary automated review loop.
