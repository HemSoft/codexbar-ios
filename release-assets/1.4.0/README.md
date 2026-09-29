# CodexBar 1.4.0 preparation

Prepared September 29, 2026 under [issue #371](https://github.com/HemSoft/codexbar-ios/issues/371).
Mode is Prepare. The preparation PR changes version settings and local metadata
only. It does not upload a binary, create an App Store Connect version, select a
build, or submit for review. Preparation merge is not release-readiness proof.

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

- [ ] Complete the four pre-release risk work items in
  [FUNCTION-RISK.md](../../FUNCTION-RISK.md#initial-baseline-and-bounded-risk-plan).
  The [product-boundary CI report](https://github.com/HemSoft/codexbar-ios/actions/runs/36341371460)
  still scores Gemini `inspectSession` at 56, Greptile `fetchUsage` at 30.72,
  card `metricTile` at 90, and Settings summary/destination/notification paths
  at 42/42/56. Passing the non-increase gate does not satisfy the documented
  requirement to reduce these functions to at most 30 before release.
- [ ] Resolve the final merged candidate SHA, date the changelog, and rerun
  the seven local perfection gates on that clean candidate.
- [ ] Pass all five automatic jobs plus manually dispatched
  `Full iOS UI validation` for that exact SHA. Review fresh function-risk,
  manual security, and manual history-performance results, including complete
  extraction and measurement evidence. A changed candidate requires new results.
- [ ] Refresh and visually inspect the six-scene iPhone/iPad screenshot set
  and two Watch images from the final candidate. Retained local iPhone/iPad
  images date to July and are not claimed as 1.4.0 evidence.
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
