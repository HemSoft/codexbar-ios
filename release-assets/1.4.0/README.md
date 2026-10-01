# CodexBar 1.4.0 preparation

Prepared September 29, 2026 under [issue #371](https://github.com/HemSoft/codexbar-ios/issues/371).
Mode is Prepare. The original [PR #372](https://github.com/HemSoft/codexbar-ios/pull/372)
changed version settings and local metadata. The October 1 asset and security
preparation continues under #373. Neither preparation uploads a binary,
creates an App Store Connect version, selects a build, or submits for review.
Preparation merge is not release-readiness proof.

## Release boundary

Read-only App Store Connect inspection confirms:

- Last live version is `1.3 (3)`, App Store version ID
  `b6f2959e-0aa7-4b1c-a8a3-01bc8ad3efa3`, selected VALID build ID
  `3addfe4f-f3fe-4cfb-a2b5-60fe57da5219`.
- No newer version or build is present. All review submissions are COMPLETE.
  Build 4 is available at this check; availability must be rechecked before upload.
- The live listing has six iPhone, six iPad, and two Watch screenshots.
- Source comparison starts at the documented 1.3 preparation commit
  [`cdc54ba`](https://github.com/HemSoft/codexbar-ios/commit/cdc54bab384e735b48b01770d08bb15da9582917).
  The retained 1.3 archive confirms all four executable bundles are `1.3 (3)`;
  it does not embed a Git SHA. The later
  [release-copy correction](https://github.com/HemSoft/codexbar-ios/pull/263)
  matches Apple's live What's New text and adds no product behavior.
- Product reconciliation ends at
  [`ceef42a`](https://github.com/HemSoft/codexbar-ios/commit/ceef42a35004c800618403d09046a826c25ec157).
  All 54 intervening main commits were compared with the 1.4.0 changelog.
  Existing 1.3 and earlier product claims are excluded from 1.4.0 What's New.
- The final release SHA must be resolved after preparation merges and after
  outstanding release fixes. Neither this product boundary nor the preparation
  PR head proves final release validation.

## October 1 preparation checkpoint

Preparation continues under [release issue #373](https://github.com/HemSoft/codexbar-ios/issues/373).
The four required risk reductions merged through
[PR #378](https://github.com/HemSoft/codexbar-ios/pull/378),
[PR #379](https://github.com/HemSoft/codexbar-ios/pull/379),
[PR #380](https://github.com/HemSoft/codexbar-ios/pull/380), and
[PR #382](https://github.com/HemSoft/codexbar-ios/pull/382).
[PR #383](https://github.com/HemSoft/codexbar-ios/pull/383) also fixed iPad card-menu
hit targets. All five issues are closed; the risk queue remains complete.

These six main commits, including preparation PR #372, were reconciled after
the original `ceef42a` product boundary. Current merged source is
[`7d466be`](https://github.com/HemSoft/codexbar-ios/commit/7d466be0e507435168c3474e6f19e8fd2b973f3a).
The refactors preserve provider behavior and account/credential isolation.
The additional customer-facing What's New sentence describes the iPad menu
fix and maps to [#381](https://github.com/HemSoft/codexbar-ios/issues/381).

A new GET-only Apple inspection on October 1 at 2:06 AM EDT still shows live
1.3 build 3, selected build VALID, no newer version/build, and only COMPLETE
review submissions. Build 4 remains provisionally unused. This is a fresh
boundary check, not upload authority or final release validation.

The description and review notes remain accurate and unchanged. Name and
subtitle remain 22/30 and 30/30 characters. Promotional text now names Gemini,
Grok, GitHub Billing, and 90-day History; it is 160/170 characters. Keywords
include those providers and History and fit the 100-character limit.
No pricing, rollout, account authority, requested permissions, or networking
behavior changes.

## Preparation screenshots and security review

The [capture manifest](capture-manifest.json) records 20 preview images, with
nine per iPhone/iPad family and two Watch images. File prefixes identify each
family and its intended storefront order. These are synthetic native app
captures, not mockups, live-provider comparisons, or final-candidate evidence.

- iPhone 17 Pro Max, 1320 x 2868 pixels, 440 x 956 points.
- iPad Pro 13-inch M5, 2064 x 2752 pixels, 1032 x 1376 points.
- Apple Watch Series 11 46mm, 416 x 496 pixels.
- Xcode 27.0 build 27A266a, iOS/watchOS 26.5, English-US, default text size.
- Order is dashboard overview, dark dashboard, Gemini, Grok, GitHub Billing,
  Widget Builder, Accounts, Copilot settings, and History. Watch has overview
  and balances. Themes are recorded per image in the manifest.

All 20 files are native-size opaque RGB PNGs. A shared lossless converter
removes the iOS PNG alpha channel and composites Watch transparency onto black
without resizing. The iOS conversion preserves every RGB pixel. Native status
bar overrides set iPhone/iPad time to 9:41; watchOS rejects that override, so
Watch images retain their real capture clocks.

History fixtures use capture-relative dates and 90 daily samples. Native
storage inspection confirmed 90 distinct days and 180 per-metric daily
snapshots on each iOS family. Copilot settings receive the prepared usage
result, so the Premium requests toggle is present. Monthly reset captions no
longer show stale fixed dates. None of these DEBUG fixtures changes customer
History, provider results, setup, or metric customization defaults.

An interaction recording is omitted because this change prepares static
storefront states and image processing. It changes no customer interaction,
navigation, animation, or timing. Final merged-candidate recapture and live
checks remain separate. The native History chart still clips its trailing
x-axis date label, tracked in [#386](https://github.com/HemSoft/codexbar-ios/issues/386).
These previews do not pass final no-clipped-text asset approval. Resolve that
UI defect or explicitly omit the affected scene before upload.

The [fresh security diagnostic](https://github.com/HemSoft/codexbar-ios/actions/runs/36823093844)
failed closed against its stale baseline. It extracted all 103 production
files and reported three known findings. [The re-review](../../SECURITY-ANALYSIS.md#release-re-review-for-140)
follows their actual guards and consumers and renews exact diagnostic
identities. Analyzer pins, extraction coverage, thresholds, and matching rules
are unchanged. A new hosted preparation-branch analysis is required; local
replay is not a hosted pass or final-candidate gate.

## Prepared version and metadata

`MARKETING_VERSION` is `1.4.0` and `CURRENT_PROJECT_VERSION` is `4` in Debug and
Release for all seven Xcode targets. Submitted executables are the iOS app,
iOS widget, Watch app, and Watch widget. Test products use the same version/build.
No automatic CI jobs, destinations, test counts, triggers, retries, or timeouts
change in preparation.

The changelog remains `1.4.0 - Unreleased` because the final release candidate
is not ready. Date it before submission once the candidate is final; preserve
all published version sections.

Local metadata sources:

- [What's New](../../fastlane/metadata/en-US/release_notes.txt)
- [Description](../../fastlane/metadata/en-US/description.txt)
- [App Review notes](../../fastlane/metadata/review_information/notes.txt)
- [Privacy policy](../../PRIVACY.md) and [support guide](../../SUPPORT.md)

The description names current providers and Watch support. Review notes disclose
provider-specific authorization, broad provider permissions, account isolation,
and the lack of a customer demo mode. The privacy policy now correctly names
GitHub Billing's existing `admin:org` permission and explains its organization
and team write capabilities, which CodexBar does not use. The support guide
already covers current feedback flows. Preparation does not change requested
permissions or data handling.

## What's New evidence map

| Claim | Changelog evidence |
| --- | --- |
| Gemini's six limits, guided sign-in, resets, and projections | [#299](https://github.com/HemSoft/codexbar-ios/issues/299), [#319](https://github.com/HemSoft/codexbar-ios/issues/319), [#330](https://github.com/HemSoft/codexbar-ios/issues/330), [#332](https://github.com/HemSoft/codexbar-ios/issues/332) |
| Grok weekly usage and separate Extra Usage Credits | [#355](https://github.com/HemSoft/codexbar-ios/issues/355), [#361](https://github.com/HemSoft/codexbar-ios/issues/361) |
| GitHub Billing allowances, spend, budgets, and projections | [#336](https://github.com/HemSoft/codexbar-ios/issues/336), [#347](https://github.com/HemSoft/codexbar-ios/issues/347), [#349](https://github.com/HemSoft/codexbar-ios/issues/349) |
| Guided OpenCode approval and workspace selection | [#353](https://github.com/HemSoft/codexbar-ios/issues/353) |
| Codex/OpenCode browser choice and separate Codex identities | [#356](https://github.com/HemSoft/codexbar-ios/issues/356), [#368](https://github.com/HemSoft/codexbar-ios/issues/368) |
| Every reported Codex window and per-metric visibility | [#270](https://github.com/HemSoft/codexbar-ios/issues/270), [#272](https://github.com/HemSoft/codexbar-ios/issues/272) |
| Separate Cursor metrics and over-limit readings | [#286](https://github.com/HemSoft/codexbar-ios/issues/286), [#292](https://github.com/HemSoft/codexbar-ios/issues/292), [#294](https://github.com/HemSoft/codexbar-ios/issues/294) |
| 90-day daily History and fresh latest readings | [#290](https://github.com/HemSoft/codexbar-ios/issues/290), [#274](https://github.com/HemSoft/codexbar-ios/issues/274) |
| Greptile reporting, recovery, navigation, and customization | [#281](https://github.com/HemSoft/codexbar-ios/issues/281), [#276](https://github.com/HemSoft/codexbar-ios/issues/276), [#277](https://github.com/HemSoft/codexbar-ios/issues/277), [#265](https://github.com/HemSoft/codexbar-ios/issues/265), [#346](https://github.com/HemSoft/codexbar-ios/issues/346) |

## Remaining release gates

These are not preparation PR merge gates. They remain required before upload
or submission and are not recorded as passed by merging preparation.

- [x] Complete the four pre-release risk work items in
  [FUNCTION-RISK.md](../../FUNCTION-RISK.md#initial-baseline-and-bounded-risk-plan).
  Their merged current-head evidence puts affected/resulting functions at no
  more than 30; all historical high-risk ceilings are resolved. The
  [main CI run](https://github.com/HemSoft/codexbar-ios/actions/runs/36811126830)
  passed. This does not replace fresh risk evidence for the final candidate.
- [ ] Resolve the final merged candidate SHA, date the changelog, and rerun
  the seven local perfection gates on that clean candidate.
- [ ] Pass all five automatic jobs plus manually dispatched
  `Full iOS UI validation` for that exact SHA. Review fresh function-risk,
  manual security, and manual history-performance results, including complete
  extraction and measurement evidence. A changed candidate requires new results.
- [ ] Recapture and visually inspect the nine-scene iPhone/iPad screenshot set
  and two Watch images from the final merged candidate. Preparation images
  are synthetic rendered app states, not live-provider or release-gate proof.
  The extra scenes put Gemini, Grok, and GitHub Billing first in the Dashboard.
  Final-candidate capture must follow the preparation merge.
- [ ] Recheck privacy answers, provider disclosures and brand permissions,
  support/privacy URLs, metadata limits, icon, packages, and all four bundles'
  privacy manifests and export-compliance declarations before archive/upload.
- [ ] Record TestFlight and physical-device checks as passed, pending, or
  skipped with reasons, never infer them from fixtures. Franz confirmed the
  second Codex account flow for [#368](https://github.com/HemSoft/codexbar-ios/issues/368).
  Other live provider comparisons remain his checks, not agent delivery prerequisites.
- [ ] Obtain Upload authority, recheck build availability, archive/export the
  exact validated SHA, verify all bundles, upload once, and wait for processing.
- [ ] Verify saved storefront metadata, screenshot previews, selected processed
  build, and release policy. Show the exact final What's New copy and obtain
  authority for that exact version/build before submitting once.
- [ ] Record Apple's submission state and identifiers, then add the next
  Unreleased section through the issue/PR workflow.

Use the release issue's comments for commands, timestamps, immutable SHAs, review
and validation evidence, and resume checkpoints. Do not store credentials or
claim a preparation check validates a later changed candidate.
