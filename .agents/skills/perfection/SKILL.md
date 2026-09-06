---
name: perfection
description: Run and repair the seven local CodexBar iOS lint, concurrency, build, and test gates. Use when asked for a perfection audit, full repository validation, merge or release readiness, quality-gate status, or systematic repair of failing iOS, SwiftPM, or watchOS checks. Report separate readiness checks outside this runner.
---

# Perfection

Audit the seven local gates below, report all failures together, and repair
failures without weakening the repository's thresholds.

## Gates

| Gate | Target |
| --- | --- |
| SwiftLint | The pinned SwiftPM plugin lints the repository with `.swiftlint.yml` strict mode |
| Strict concurrency | `scripts/check-strict-concurrency.sh` runs complete checking and its existing diagnostic policy |
| iOS build | `CodexBarIOS` builds for an available iPhone simulator with warnings treated as errors |
| iOS tests | All `CodexBarIOSTests` pass |
| SwiftPM smoke | `CodexBarIOSSmokeTests` exits successfully |
| watchOS build | `CodexBarWatch` builds for an available Apple Watch simulator with warnings treated as errors |
| watchOS tests | All `CodexBarWatchTests` pass |

The standalone lint command is
`xcrun swift package plugin --allow-writing-to-package-directory swiftlint lint --reporter xcode .`.
Use the resolved `SwiftLintPlugins` version and preserve all lint/compiler
thresholds. Target-level build plugins do not replace this repository-wide gate.

This runner does not run the separate [UI journeys](../../../UI-TESTING.md),
[function coverage and risk analysis](../../../FUNCTION-RISK.md),
[security analysis](../../../SECURITY-ANALYSIS.md), or
[performance budgets](../../../USAGE-HISTORY-PERFORMANCE.md). These checks are
supported elsewhere in the repository. Verify the applicable checks and live
GitHub requirements before declaring merge or release readiness. Do not count
an unrun or unavailable analyzer as passing or invent unsupported gates.

## Audit

Run the deterministic audit from the repository root:

```sh
./.agents/skills/perfection/scripts/run-perfection.sh
```

The runner:

- selects the first available iPhone simulator and an Apple Watch simulator
  compatible with the active Xcode SDK, matching CI;
- uses `/Applications/Xcode.app/Contents/Developer` unless `DEVELOPER_DIR` is
  already set; the existing strict-concurrency script pins that Xcode path;
- disables code signing and treats Swift and Clang warnings as errors for
  simulator build/test gates; lint and concurrency retain their existing policies;
- runs all gates even when an earlier gate fails;
- stores each gate's complete log, simulator test result bundles, and a summary
  under the ignored `DerivedData/Perfection/` directory; the existing lint and
  concurrency commands retain their standard dependency/build cache locations;
- exits successfully only when every selected gate passes.

Override simulator selection only when the task requires a particular
destination:

```sh
PERFECTION_IOS_DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=latest' \
PERFECTION_WATCH_DESTINATION='platform=watchOS Simulator,name=Apple Watch Series 11 (46mm),OS=latest' \
  ./.agents/skills/perfection/scripts/run-perfection.sh
```

Run one gate while diagnosing or verifying a focused fix:

```sh
./.agents/skills/perfection/scripts/run-perfection.sh --gate ios-tests
```

Valid gate names are `swiftlint`, `strict-concurrency`, `ios-build`, `ios-tests`,
`swiftpm-smoke`, `watch-build`, and `watch-tests`. Use `--list` to print them.

Report the final score, each failing gate, and the audit artifact directory.
Summarize the root cause from the complete gate log rather than relying only on
the displayed tail.

## Fix

For `perfection fix`:

1. Run the full audit and keep its artifact path.
2. Fix build and compiler-warning failures first; correct root causes instead
   of weakening warning settings.
3. Fix failing tests and production defects next. Preserve test intent; do not
   delete, skip, or loosen assertions merely to make a gate pass.
4. Rerun the affected gate with `--gate`.
5. After all focused checks pass, rerun the full audit.
6. Update `CHANGELOG.md` when the resulting change is user-visible or affects
   developer workflows, following `AGENTS.md`.

Follow the repository's issue-first branch and pull-request workflow unless the
user explicitly authorizes a narrower exception.

## Status

Print the most recent local summary without rerunning gates:

```sh
./.agents/skills/perfection/scripts/run-perfection.sh --status
```

Treat status as historical evidence, not proof about the current worktree. Run
a fresh audit before declaring the current revision ready. The score counts
only selected gates, and the summary names the separate checks it did not run.

Verify runner selection and failure reporting without invoking Xcode:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_perfection_runner.py' -v
```

## Boundaries

- Do not deploy to, install on, or launch a connected iPhone during a normal
  audit. Device signing is a separate workflow with keychain implications.
- Do not modify simulator state beyond what `xcodebuild` needs for its selected
  destinations.
- Do not clean global Xcode caches or DerivedData. Audit artifacts stay inside
  this repository's ignored `DerivedData/Perfection/` path.
- Do not use the interactive `run.sh`; it installs, launches, and opens the
  Simulator app, which is unnecessary for quality validation.
