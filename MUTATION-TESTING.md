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

The initial scope deliberately includes only
`CodexBarIOS/Services/DashboardUsageSorter.swift`. The runner dynamically
excludes every other service source, and the fixed configuration runs the
`CodexBarIOS` scheme through
`CodexBarIOSTests/AppAndWidgetTests` on an iPhone 17 simulator. Tests, build
output, SwiftUI presentation, fixtures, widgets, watch rendering, platform
wrappers, credentials, and networking are outside this pilot.

Relational, boolean, logical, arithmetic, conditional-negation, and ternary
operators are enabled. Remove-side-effects mutations remain disabled until a
future pilot can establish their signal quality.

## Reproducing the run

Run the complete uncached baseline:

```sh
./scripts/run-mutation-pilot.sh \
  --no-cache \
  --output build/mutation-testing/baseline.json \
  --html-output build/mutation-testing/baseline.html
```

Omit `--no-cache` for normal manual follow-up runs. The tool cache and downloaded
binary live under ignored paths. XCTest execution is intentionally serial, with
a 120-second per-mutant timeout, because the selected tool forces serial XCTest
workers for deterministic simulator results.

The tool copies the repository into a temporary sandbox before rewriting source.
Version 1.3.0 removes its active sandbox on normal completion and cleans
orphaned `xmr-*` sandboxes at the next startup after an interrupted run. The
pilot confirmed that a completed and an interrupted run left the production
source tree unchanged.

## Baseline

Measured on 2026-07-25 with Xcode 26.6 and an iPhone 17 simulator:

| Result | Count |
| --- | ---: |
| Total | 58 |
| Killed | 35 |
| Survived | 23 |
| No coverage | 0 |
| Timeout | 0 |
| Unviable | 0 |
| Score | 60.3% |
| Wall-clock time | 40m 1s |

The report classified four incompatible discoveries during schematization, but
all four were successfully rebuilt and executed by the fallback path; the
final unviable count is therefore zero.

## Survivor triage

The 23 survivors divide into three useful groups:

- **8 actionable test gaps.** Sorting assertions did not isolate projected-hit
  presence, projected-fraction direction, final stable ties, invalid
  zero-limit/zero-elapsed projections, elapsed-rate division, or a hit exactly
  at the period end.
- **13 equivalent or no-value mutations.** These are inclusive comparisons
  behind an earlier inequality guard, comparisons of distinct enumeration
  offsets, or redundant zero guards whose later rate guard produces the same
  result.
- **2 tool limitations.** Mutating the name of `BalanceRank`'s custom `<`
  operator caused Swift to synthesize an equivalent `Comparable` implementation,
  so neither mutation changed runtime behavior.

Focused tests were added for every actionable category:

| Baseline gap | Focused regression |
| --- | --- |
| A projected hit was not distinguished from no projected hit, including an exact period-end hit. | `testDashboardUsageSorterPrioritizesProjectionHittingExactlyAtPeriodEnd` |
| Reversing projected-fraction priority survived when neither account reached its limit. | `testDashboardUsageSorterOrdersProjectedFractionsWhenLimitsAreNotReached` |
| Reversing the final stable tie and admitting invalid zero-limit/zero-elapsed projections survived. | `testDashboardUsageSorterPreservesEqualScoresAndIgnoresInvalidProjections` |
| Replacing elapsed-rate division with multiplication survived. | `testDashboardUsageSorterUsesElapsedRateToOrderLimitHits` |

These tests pass in the focused XCTest class and remain part of the normal
`CodexBarIOSTests` regression suite. Equivalent mutants are documented rather
than driving production changes that do not alter observable behavior.

Post-test confirmation reruns provide representative before/after evidence:

- Boolean mutations improved from 3 killed and 2 survived to 4 killed and 1
  survived. Both nil/non-nil projected-hit branches are now killed; the sole
  survivor is the unreachable `.none/.none` branch behind the outer inequality
  guard.
- Both arithmetic mutations are killed after the elapsed-rate regression was
  added; the baseline had allowed the division-to-multiplication mutation to
  survive.

## Decision

Keep the runner for occasional, manually scoped pilots on branch-heavy
deterministic logic. Do not add scheduled CI or a blocking score threshold yet:
40 minutes for one source file is too expensive for per-PR use, and the raw
60.3% score includes 15 equivalent/tool-limited survivors. Any future threshold
must exclude equivalent and unviable mutations and be based on a broader
measured sample, not a target of 100%.
