# Function coverage and risk

The required `iOS tests` and `watchOS tests` CI jobs collect coverage and run
`scripts/function-risk/measure.py`. A measurement error or failed baseline
comparison fails that existing required status. Both jobs publish artifacts named
`function-risk-ios` and `function-risk-watch`, including raw xccov coverage,
SwiftLint output, source declarations, the full JSON report and a Markdown review
queue. Artifacts remain available for 14 days. A collection failure produces
`failure.txt`; absent artifacts after collection was attempted also fail the
upload step. If a test suite fails before collection, the job preserves its
xcresult diagnostics and skips the risk upload.

## Measurement contract

Tools are pinned in `scripts/function-risk/policy.json`: Xcode 26.6 build 17F113
provides the compiler, SwiftSyntax parser and xccov; SwiftLint 0.65.1 comes from
the existing exact SwiftLintPlugins dependency and its checksum-verified binary.
Python 3.9 or later uses only the standard library. Changing the Xcode or
SwiftLint pin requires reviewing the baseline and recording the evidence below.
An unexpected tool version fails collection.

The score is `CRAP = CC^2 * (1 - coverage)^3 + CC`. Coverage is each function's
`coveredLines / executableLines` from `xccov view --report --json`, never a
file, target or repository average. Xccov exposes executable-line coverage,
not branch coverage. This cannot establish that both outcomes of a condition
were tested when they share a covered line. Switch to branch coverage only with
a reviewed tool/baseline migration.

`CC` preserves the issue #306 audit's **SwiftLint decision count**, which starts
at zero. It is not the conventional McCabe count that starts at one. The pinned
[SwiftLint rule](https://github.com/realm/SwiftLint/blob/0.65.1/Source/SwiftLintBuiltInRules/Rules/Metrics/CyclomaticComplexityRule.swift)
counts `if`, `guard`, loops, `catch` and switch cases, subtracts fallthroughs,
and measures functions and initializers. It excludes nested declarations from
the enclosing function's count and includes closure decisions in that function.
A separate measurement configuration reports even zero-decision declarations;
it does not change the strict lint thresholds used to check source style.

The tool parses every production source root with the selected Xcode's
SwiftSyntax, then reads production membership from the project's Sources build
phases. It joins each declaration's header span to one xccov function and the
exact SwiftLint line/column. Missing or ambiguous joins remain unmatched.
Signatures use syntax tokens and type scope, so formatting and line shifts do
not change baseline identity. Repeated signatures use their source-order
alternative number. Renames and removals require explicit baseline review.

Each report keeps its platform and selected coverage target. The iOS suite
uses `CodexBarIOS.app` and `CodexBarIOSWidget.appex`; the watch suite uses
`CodexBarWatch.app` and `CodexBarWatchWidget.appex`. When source is compiled into
both app and widget, the app owns its score. The other copy's coverage remains
in the inventory. We never choose whichever target has higher coverage or
combine iOS and watch counters. Incidental embedded products in another
platform's result remain listed with a reason.

## Gate and review queue

- New production declarations above 30 fail. Existing production declarations
  above 30 may not exceed their explicit baseline ceiling.
- Score comparisons use exact rational arithmetic from integer counts. Rounding
  to four decimals happens only in the Markdown display.
- Scores 15 through 30 form a review queue in the report. A score of exactly 30
  is allowed; exactly 15 enters the queue.
- Unmatched production declarations fail unless an individual baseline entry
  explains the instrumentation gap and matches both source hash and complexity.
  Changed code must not inherit an exception. Resolved exceptions must be removed.
- Missing targets, empty target coverage, missing complexity, malformed measured
  line counts, missing production source roots, or stale high-risk identities
  fail collection or the gate. A removed high-risk declaration requires a
  reviewed baseline edit, even if the removal is an improvement.

Accessors, stored-property initialization, standalone closures and synthesized
or generated symbols have no independent SwiftLint func/init complexity. The
report lists their coverage with a reason and assigns no artificial score.
An unjoined coverage symbol also remains visible. These are measurement limits,
not claims that the code is covered. Files with no func/init bodies are listed.
There is no whole-app coverage percentage target.

Screenshot exclusions are explicit in `policy.json`: the DEBUG-only fixture
file and the exact screenshot scene-routing declaration. Their available
measurements remain visible. Normal UI, authentication, widget and platform code
are production code. The only initial unmatched exceptions are the two
non-iOS `#else` fallback bodies in `WatchSnapshotCoordinator.swift`. Their
hashes lock the currently uncompiled source; neither receives a coverage score.

## Reproduce

Run from the repository root with the pinned Xcode selected. Use fresh result
paths for each run. Simulator runtimes are recorded in the xcresult; the
initial baseline used iOS 27.0 and watchOS 26.5 simulators. CI selects an
available iPhone and the compatible watch simulator as it does for ordinary
tests. Differences in instrumentation or coverage still must meet the same
baseline; do not average or loosen ceilings to conceal a platform discrepancy.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p DerivedData
risk_run="$(mktemp -d "$PWD/DerivedData/function-risk.XXXXXX")"
xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarIOS \
  -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -enableCodeCoverage YES -resultBundlePath "$risk_run/ios.xcresult" \
  CODE_SIGNING_ALLOWED=NO test
watch_device_id="$(./scripts/select-watch-simulator.sh)"
xcodebuild -project CodexBarIOS.xcodeproj -scheme CodexBarWatchTests \
  -skipPackagePluginValidation \
  -destination "platform=watchOS Simulator,id=$watch_device_id" \
  -enableCodeCoverage YES -resultBundlePath "$risk_run/watch.xcresult" \
  CODE_SIGNING_ALLOWED=NO test
python3 scripts/function-risk/measure.py --platform ios \
  --result "$risk_run/ios.xcresult" --output "$risk_run/ios"
python3 scripts/function-risk/measure.py --platform watch \
  --result "$risk_run/watch.xcresult" --output "$risk_run/watch"
python3 -m unittest discover -s scripts/tests -p 'test_function_risk.py' -v
```

Create `DerivedData` first if it does not exist. To inspect coverage directly:

```sh
xcrun xccov view --report --json "$risk_run/ios.xcresult"
xcrun xccov view --report --json "$risk_run/watch.xcresult"
```

The regression fixtures construct a six-decision uncovered function whose
score is 42, prove the gate fails, then restore full coverage and prove it
passes. A second fixture worsens an existing score by less than the report's
display precision and still fails. Other fixtures cover missing/ambiguous
coverage, empty denominators, platform separation, stale exceptions and source
identity. Fixtures use isolated temporary files, so no broken source remains.

## Initial baseline and bounded risk plan

Issue [#306](https://github.com/HemSoft/codexbar-ios/issues/306), source revision
`78b6a213c53ae4a90e61cd4802d31aafbeb91e35`, measured September 5, 2026. Both suites
passed, with 654 iOS and 59 watch tests and no failures or skips. The inventory
has 1,182 scored iOS declarations, 2 unmatched iOS fallbacks and 7 screenshot
exclusions; watch has 101 scored declarations and no unmatched declarations.
These are platform-specific counts, so shared source can appear in both.

The initial ceilings below are captured as exact line counts and decision
counts in `scripts/function-risk/baseline.json`. Six production risks remain;
this change establishes measurement and a gate without claiming to fix them.
Before the next production release, handle the following four bounded work
items through the repository's issue-first workflow, starting with sign-in and
pagination. Review the remaining ceilings in each item and lower or remove
entries only after fresh coverage proves the improvement.

| Work item | Existing functions | Initial CRAP | Completion evidence |
| --- | --- | ---: | --- |
| Gemini sign-in session state | `GeminiBrowserSignInSession.inspectSession()` | 56 | Test signed-out, missing-cookie, loading, validated and failed-session paths through an injectable state boundary; reduce score to at most 30. |
| Greptile pagination | `GreptileUsageProvider.fetchUsage(for:)` | 30.721360 | Exercise remaining early exit and pagination failure paths; preserve incomplete-scan behavior and reduce score to at most 30. |
| Dashboard metric dispatch | `ProviderUsageCard.metricTile(_:)` | 156 | Extract/test metric selection and presentation decisions without screenshot automation; reduce each resulting function to at most 30. |
| Settings dispatch and notifications | `SettingsView.summary(for:)`, `settingsDestinationView(_:)`, `updateGitHubStatusNotificationSetting(isEnabled:recovery:)` | 42, 42, 56 | Test destination mapping and notification permission outcomes; reduce each function to at most 30. |

Baseline edits must include the source revision, tool versions, fresh reports,
changed counts and a concrete reason in the PR and this document. Do not
regenerate the baseline in CI. Reviewers must distinguish a verified reduction,
a renamed or removed function, a tool migration and an attempted increase. A
new production risk requires remediation, not a routine baseline addition.
