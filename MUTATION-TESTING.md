# Mutation-Testing Pilot

CodexBar retains mutation testing as a targeted manual quality check. It is not
a pull-request gate or a whole-project score target.

## Tool and scope

The pilot pins
[`swift-mutation-testing` v1.3.0](https://github.com/ericodx/swift-mutation-testing/releases/tag/v1.3.0)
(commit `8d8d03e28f06665c3fc6f36ccdc7cac244a584f6`). The runner downloads the
release archive and verifies this SHA-256 before executing it:

```text
ad35efeca06baa1da2e5375932406cbc37a103b597fd1d1fa780968c2118c8d3
```

This tool was selected over
[Muter](https://github.com/muter-mutation-testing/muter) because the pinned
release supports Xcode/XCTest projects, mutant schemata, result caching,
Stryker-compatible JSON and HTML reports, and signal-aware cleanup of isolated
`xmr-*` sandboxes. Muter's latest tagged release is from 2023; it remains the
fallback if the selected tool stops working with the active Xcode toolchain.

The scope deliberately includes only two deterministic services:

- `CodexBarIOS/Services/DashboardUsageSorter.swift`, the original branch-heavy
  ordering baseline.
- `CodexBarIOS/Services/AppReviewPromptPolicy.swift`, a compact state machine
  whose clock, app version, thresholds, and `UserDefaults` store are injectable
  and whose eligibility helper is pure. It adds meaningful boundary and
  persistence decisions without crossing UI, StoreKit, or networking edges.

The runner dynamically excludes every other service source, and the fixed
configuration runs the `CodexBarIOS` scheme through
`CodexBarIOSTests/AppAndWidgetTests` on an iPhone 17 simulator. Tests, build
output, SwiftUI presentation, fixtures, widgets, watch rendering, platform
wrappers, credentials, keychain access, and live networking remain outside this
pilot.

Relational, boolean, logical, arithmetic, conditional-negation, and ternary
operators are enabled. Remove-side-effects mutations remain disabled until a
future pilot can establish their signal quality.

## Reproducing the run

Run the complete uncached baseline:

```sh
./scripts/run-mutation-pilot.sh \
  --no-cache \
  --output build/mutation-testing/expanded-baseline.json \
  --html-output build/mutation-testing/expanded-baseline.html
```

Omit `--no-cache` for normal manual follow-up runs. The tool cache and downloaded
binary live under ignored paths. XCTest execution is intentionally serial, with
a 120-second per-mutant timeout, because the selected tool forces serial XCTest
workers for deterministic simulator results.

The runner first creates a detached temporary worktree and overlays the current
working tree, so reports reflect local tests without rewriting production
source. The generated mutant schema cannot satisfy the normal source-size lint
limits, so the runner removes only the six SwiftLint build-tool dependencies
from the disposable Xcode project. The independent strict SwiftLint gate still
checks every real source file. Version 1.3.0 then creates and removes its own
`xmr-*` sandbox; the runner copies reports back and removes its temporary
worktree on success, failure, or interruption. The ignored mutation cache is
copied into the disposable worktree and back out after each run, so normal
follow-up runs reuse the same stable sandbox path and cached result keys while
`--no-cache` remains available for fresh measurements. Cache copy-back stays
disabled until the initial staging copy completes, so a partial staging failure
cannot replace a valid repository cache. An atomic lock records
both the wrapper and active mutation-tool process, refuses concurrent runs from
the same worktree, and reclaims a lock only after no recorded or workspace-bound
process is still running. Exit/signal cleanup saves the cache and relative
JSON, HTML, or Sonar reports configured in `.swift-mutation-testing.yml` or on
the command line before removing the disposable worktree; a sandbox-side
manifest lets the next run recover those custom report paths after an
untrappable process or host failure.

## Expanded baseline

Measured on 2026-07-31 with Xcode 26.6 and an iPhone 17 simulator:

| Result | Count |
| --- | ---: |
| Total | 88 |
| Killed | 67 |
| Survived | 21 |
| No coverage | 0 |
| Timeout | 0 |
| Unviable | 0 |
| Score | 76.1% |
| Wall-clock time | 98m 2s |

| Source | Total | Killed | Survived | Score |
| --- | ---: | ---: | ---: | ---: |
| `AppReviewPromptPolicy.swift` | 30 | 24 | 6 | 80.0% |
| `DashboardUsageSorter.swift` | 58 | 43 | 15 | 74.1% |

Ten incompatible discoveries were rebuilt and executed by the fallback path;
none remained unviable. Three sorter mutants terminated the test process and
appear as `Crash` in the JSON report, which the tool correctly aggregates into
the killed count above.

## Survivor triage

Every survivor falls into one of these categories:

- **6 actionable App Review policy mutations in 4 categories.** Three
  arithmetic mutations shortened the default seven-day engagement duration;
  one relational mutation removed the minimum-refresh gate after enough time;
  one boolean mutation returned success before the engagement window elapsed;
  and one boolean mutation returned success for a version that had already
  requested a review.
- **13 equivalent or no-value sorter mutations.** Inclusive comparisons cannot
  change results behind prior inequality guards or when comparing distinct
  enumeration offsets. The zero-current and zero-rate mutations also converge
  on the same later nil-return path.
- **2 sorter tool limitations.** Mutating the name of `BalanceRank`'s custom
  `<` operator caused Swift to synthesize an equivalent `Comparable`
  implementation, so neither mutation changed runtime behavior.

Focused tests cover each actionable App Review category without changing
production behavior:

| Baseline gap | Focused regression |
| --- | --- |
| The default engagement interval was not isolated from the refresh-count threshold. | `testAppReviewPromptPolicyDefaultEngagementDurationIsSevenDays` |
| Enough elapsed time could bypass the required successful-refresh count. | `testAppReviewPromptPolicyStillRequiresRefreshCountAfterEngagementWindow` |
| The engagement guard was not exercised both before and beyond its boundary with the count already satisfied. | `testAppReviewPromptPolicyHonorsEngagementWindowBeyondExactBoundary` |
| Same-version suppression was asserted before the policy could reach that guard again. | `testAppReviewPromptPolicyRejectsSameVersionAfterEligibilityRecurs` |

The eligibility regression also confirms that a monetary-only result counts as
usable data. Equivalent and tool-limited sorter survivors remain documented
rather than driving production changes that do not alter observable behavior.

Run the App Review confirmation independently with:

```sh
./scripts/run-mutation-pilot.sh \
  --no-cache \
  --exclude CodexBarIOS/Services/DashboardUsageSorter.swift \
  --output build/mutation-testing/app-review-confirmation.json \
  --html-output build/mutation-testing/app-review-confirmation.html
```

Measured after adding the focused regressions, all six previously surviving App
Review mutants were killed. The complete 30-mutant run reported 27 killed, zero
survived, and three 120-second timeouts in 48m 43s. To distinguish slow simulator
execution from survivors, the three affected operator families were rerun with a
240-second timeout:

```sh
./scripts/run-mutation-pilot.sh \
  --no-cache \
  --timeout 240 \
  --exclude CodexBarIOS/Services/DashboardUsageSorter.swift \
  --operator NegateConditional \
  --operator RelationalOperatorReplacement \
  --operator ArithmeticOperatorReplacement \
  --output build/mutation-testing/app-review-timeout-confirmation.json \
  --html-output build/mutation-testing/app-review-timeout-confirmation.html
```

That isolated run killed all 22 selected mutants with zero survivors, timeouts,
unviable mutants, or uncovered mutants in 28m 8s. This includes each of the three
mutants that timed out in the complete confirmation run.

## Decision

Keep the runner for occasional, manually scoped investigations. Do not add
scheduled CI or a blocking score threshold: expanding from 58 to 88 mutants
increased wall-clock time from about 40 minutes to 98 minutes, which is too
expensive for routine execution. The raw 76.1% baseline also includes 15
equivalent or tool-limited sorter survivors. Any future threshold must exclude
equivalent and unviable mutants and be justified by a broader measured sample,
not a target of 100%.
