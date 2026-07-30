# Changelog

Notable changes to CodexBar are documented here. Entries describe shipped app
behavior; development-only changes are listed separately when they affect
building, testing, or releasing the app.

## 1.2.0 - Unreleased

### Added

- Added a welcoming first-run dashboard with a prominent Add Account action
  that guides people through provider selection and directly into setup, with
  the same flow available from Settings.
  ([#195](https://github.com/HemSoft/codexbar-ios/issues/195))
- Added configurable Apple Watch complications for inline, circular,
  rectangular, and corner placements, with cached provider usage, honest
  freshness and stale states, and warning or critical context at a glance.
  ([#190](https://github.com/HemSoft/codexbar-ios/issues/190))
- Added a clear path for connecting additional ChatGPT / Codex accounts with
  private browser sign-in, duplicate-account protection, and independently
  preserved credentials and settings for each identity.
  ([#185](https://github.com/HemSoft/codexbar-ios/issues/185))
- Added private, account-free problem and improvement email drafts with
  recognizable subjects, structured editable prompts, optional reviewed
  diagnostics, and copyable fallback details when no email app is configured;
  public GitHub forms remain available as an alternative.
  ([#177](https://github.com/HemSoft/codexbar-ios/issues/177))
- Added previewable, privacy-safe problem diagnostics for provider, widget, and
  Apple Watch failures, with optional technical categories, copy support, and
  bounded GitHub bug-form prefill that never includes account labels,
  credentials, usage, balances, raw responses, or stored snapshots.
  ([#164](https://github.com/HemSoft/codexbar-ios/issues/164))
- Added Apple Watch metric prioritization that follows each iPhone card’s saved
  order, plus per-metric controls to inherit, always show, or always hide a
  metric on Watch without changing the iPhone dashboard.
  ([#146](https://github.com/HemSoft/codexbar-ios/issues/146))
- Added a width-aware, row-aligned two-column dashboard for sufficiently wide
  iPads, with automatic single-column fallbacks and accessible account-card
  reordering. ([#145](https://github.com/HemSoft/codexbar-ios/issues/145))
- Added a live Customize Card editor for rearranging, resizing, restyling,
  showing, and hiding metric tiles, with undo/reset controls, new-metric
  markers, accessible move actions, and reusable layouts across compatible
  accounts. ([#144](https://github.com/HemSoft/codexbar-ios/issues/144))
- Added adaptive metric-tile grids to provider cards, including saved
  automatic, half, and full widths, single-column accessibility layouts, and
  complete per-tile details with available history.
  ([#143](https://github.com/HemSoft/codexbar-ios/issues/143))
- Added a versioned, account-specific metric layout foundation that preserves
  existing visibility and visualization choices while enabling saved tile
  order and adaptive width preferences. ([#142](https://github.com/HemSoft/codexbar-ios/issues/142))
- Added account-specific show/hide controls for every usage, balance, and
  monetary metric on multi-metric dashboard cards, with matching Apple Watch
  visibility and unchanged widget selections. ([#132](https://github.com/HemSoft/codexbar-ios/issues/132))
- Added a Configure Account shortcut to each dashboard card menu so users can
  edit the exact account and refresh its usage without navigating through
  Settings. ([#131](https://github.com/HemSoft/codexbar-ios/issues/131))
- Added compact, accessible subscription-plan badges to ChatGPT / Codex,
  Claude, and GitHub Copilot dashboard cards while preserving custom account
  names and omitting unknown or unverified tiers.
  ([#130](https://github.com/HemSoft/codexbar-ios/issues/130))
- Added current-pace projections to OpenCode Go quota windows when their reset
  boundaries are trustworthy, while leaving ambiguous windows and Zen credit
  balances unprojected. ([#128](https://github.com/HemSoft/codexbar-ios/issues/128))
- Added OpenCode Go subscription tracking for the rolling 5-hour, weekly, and
  monthly usage limits, including provider-reported reset times alongside the
  existing Zen credit balance. ([#122](https://github.com/HemSoft/codexbar-ios/issues/122))
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
  history, and in widgets, alongside the existing OpenRouter and OpenCode Zen
  balances. ([#66](https://github.com/HemSoft/codexbar-ios/issues/66))

### Changed

- Corrected widget freshness labels so medium, large, and extra-large widgets
  report the age of the oldest usage data they actually display, including
  cached and partially refreshed values. ([#202](https://github.com/HemSoft/codexbar-ios/issues/202))
- Organized Settings into a compact, adaptive category list with focused
  destinations for accounts, dashboard preferences, alerts, widgets, support,
  and recovery while keeping urgent data-recovery needs prominent.
  ([#200](https://github.com/HemSoft/codexbar-ios/issues/200))
- Consolidated Settings account creation into one provider-neutral Add Account
  action at the top of the Accounts section, including for additional ChatGPT /
  Codex accounts. ([#198](https://github.com/HemSoft/codexbar-ios/issues/198))
- Simplified the Settings version label to show only the public app version
  while retaining the internal build number for diagnostics and support.
  ([#170](https://github.com/HemSoft/codexbar-ios/issues/170))
- Replaced the single support link with a quiet Feedback & Support hub for
  reporting problems, suggesting improvements, viewing known issues, reading
  support guidance, and rating CodexBar, with clear public-report privacy
  warnings and safe version and operating-system prefill.
  ([#163](https://github.com/HemSoft/codexbar-ios/issues/163))
- Made public support requests easier and safer with separate structured forms
  for reporting problems and suggesting improvements, plus clearer routing for
  known issues and privacy-sensitive concerns.
  ([#162](https://github.com/HemSoft/codexbar-ios/issues/162))
- Simplified provider cards by moving routine Claude and Cursor context plus
  Cursor alert details into an accessible More Information sheet, and by
  hiding safe projection copy while keeping limit-hit warnings visible.
  ([#160](https://github.com/HemSoft/codexbar-ios/issues/160))
- Let users open a native inventory from the Codex card, inspect each saved
  reset and its localized expiration, and explicitly choose which reset to use.
  ([#101](https://github.com/HemSoft/codexbar-ios/issues/101))
- Restricted browser sign-in callbacks to this device, matched callback hosts
  to each provider's requirements, and made stalled ChatGPT, Claude, and GitHub
  Copilot sign-ins time out cleanly. ([#52](https://github.com/HemSoft/codexbar-ios/issues/52))

### Fixed

- Ensured a newly installed Apple Watch companion requests and receives the
  current dashboard without waiting for an unrelated iPhone data change, while
  preserving the last good snapshot whenever the phone is unavailable.
  ([#191](https://github.com/HemSoft/codexbar-ios/issues/191))
- Made private feedback copy-first and warned before opening an external mail
  composer that it may display and use the currently selected sending account.
  ([#181](https://github.com/HemSoft/codexbar-ios/issues/181))
- Corrected Cursor history to track Total usage by default instead of whichever
  hidden or secondary metric is highest, while adding separate stable history
  series for Total, Auto, API, and On-demand usage.
  ([#178](https://github.com/HemSoft/codexbar-ios/issues/178))
- Kept the current usage percentage prominent in widgets while preserving
  projections as secondary context in fills, details, and severity.
  ([#157](https://github.com/HemSoft/codexbar-ios/issues/157))
- Centered semicircular usage gauges within dashboard and Customize Card
  metric tiles across compact, full-width, and accessibility layouts.
  ([#156](https://github.com/HemSoft/codexbar-ios/issues/156))
- Clarified that OpenRouter credit balances require a sensitive Management API
  Key stored only in Keychain, and now distinguish invalid credentials from
  keys that lack account-credits permission.
  ([#152](https://github.com/HemSoft/codexbar-ios/issues/152))
- Removed duplicated percentages from semicircular usage gauges and centered
  their values while preserving aligned, accessible metric tiles.
  ([#151](https://github.com/HemSoft/codexbar-ios/issues/151))
- Prevented additional iPad windows from starting duplicate dashboard refresh,
  history, alert, widget, and Apple Watch publication work.
  ([#139](https://github.com/HemSoft/codexbar-ios/issues/139))
- Matched Claude's current-session and All models labels, represented the idle
  session state, and kept provider-reported usage-credit balance separate from
  monthly spend headroom. ([#125](https://github.com/HemSoft/codexbar-ios/issues/125))
- Labeled the OpenCode integration as Go + Zen, Go, or Zen based on the
  products available in each workspace while preserving custom account labels.
  ([#127](https://github.com/HemSoft/codexbar-ios/issues/127))
- Let Claude dashboard cards start account-specific sign-in when credentials are
  missing or rejected, preserve the existing credential on cancellation or
  failure, and refresh the card automatically after successful recovery.
  ([#126](https://github.com/HemSoft/codexbar-ios/issues/126))
- Kept the saved GitHub Copilot identity and sign-in method aligned with the
  existing credential when a replacement cannot be stored securely.
  ([#117](https://github.com/HemSoft/codexbar-ios/issues/117))
- Preserved saved account grouping when group data is unreadable, surfaced the
  problem in Settings, and required explicit recovery before replacing damaged
  groups or ungrouping accounts. ([#116](https://github.com/HemSoft/codexbar-ios/issues/116))
- Kept saved accounts and their dashboard settings consistent with Keychain
  credentials when an all-account reset only partially succeeds, while leaving
  failed accounts available to retry. ([#115](https://github.com/HemSoft/codexbar-ios/issues/115))
- Reported damaged saved usage history on the dashboard, preserved its raw data
  until an explicit reset, and resumed recording after recovery.
  ([#109](https://github.com/HemSoft/codexbar-ios/issues/109))
- Surfaced damaged saved account lists in Settings, preserved their raw data and
  Keychain credentials until explicit replacement, and restored normal account
  saving after recovery. ([#108](https://github.com/HemSoft/codexbar-ios/issues/108))
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

- Condensed the standing agent guide and moved connected-device deployment and
  signing recovery into a focused runbook with live identifier discovery and
  explicit dedicated-keychain safeguards.
  ([#197](https://github.com/HemSoft/codexbar-ios/issues/197))
- Added a repository-local Perfection skill that discovers available simulators,
  runs every supported iOS, SwiftPM, and watchOS build and test gate, treats
  compiler warnings as errors, and preserves consolidated audit diagnostics.
  ([#189](https://github.com/HemSoft/codexbar-ios/issues/189))
- Added deterministic T3 Code project branding using the canonical CodexBar
  iOS app icon. ([#187](https://github.com/HemSoft/codexbar-ios/issues/187))
- Upgraded the pinned CI checkout and failed-test diagnostic upload actions to
  their current v7.0.1 releases while preserving least-privilege access and
  failure-only `.xcresult` retention.
  ([#183](https://github.com/HemSoft/codexbar-ios/issues/183))
- Isolated browser-auth callback ports and network fixtures across parallel test
  workers, and preserved iOS `.xcresult` diagnostics when CI tests fail.
  ([#173](https://github.com/HemSoft/codexbar-ios/issues/173))
- Required every code, documentation, configuration, build, and process change
  to start from a GitHub issue and a clean, synchronized `main`, use an
  issue-specific branch, and deliver the change through a linked pull request.
  ([#169](https://github.com/HemSoft/codexbar-ios/issues/169))
- Stopped repository-change intake after its defining GitHub issue is identified
  unless the user explicitly overrides same-turn implementation.
  ([#193](https://github.com/HemSoft/codexbar-ios/issues/193))
- Added a pinned, sandboxed mutation-testing pilot for dashboard sorting,
  documented its measured baseline and survivor triage, and strengthened
  projection-ordering boundary coverage without adding a blocking CI gate.
  ([#124](https://github.com/HemSoft/codexbar-ios/issues/124))
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
