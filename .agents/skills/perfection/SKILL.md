---
name: perfection
description: Run and repair the complete CodexBar iOS quality-gate suite. Use when asked for a perfection audit, full repository validation, merge or release readiness, all supported builds and tests, quality-gate status, or systematic repair of failing iOS, SwiftPM, or watchOS checks.
---

# Perfection

Audit every quality gate that CodexBar iOS actually supports, report all
failures together, and drive the repository back to a fully passing state.

## Gates

| Gate | Target |
| --- | --- |
| iOS build | `CodexBarIOS` builds for an available iPhone simulator with warnings treated as errors |
| iOS tests | All `CodexBarIOSTests` pass |
| SwiftPM smoke | `CodexBarIOSSmokeTests` exits successfully |
| watchOS build | `CodexBarWatch` builds for an available Apple Watch simulator with warnings treated as errors |
| watchOS tests | All `CodexBarWatchTests` pass |

Do not invent gates for formatting, linting, dependency vulnerabilities, code
coverage, or complexity. The repository does not currently configure supported
tools or thresholds for them. Add a gate only when the repository adopts the
corresponding tool and documents it in `AGENTS.md`.

## Audit

Run the deterministic audit from the repository root:

```sh
./.agents/skills/perfection/scripts/run-perfection.sh
```

The runner:

- selects the first available iPhone and Apple Watch simulators, matching CI;
- uses `/Applications/Xcode.app/Contents/Developer` unless `DEVELOPER_DIR` is
  already set;
- disables code signing and treats Swift and Clang warnings as errors;
- runs all gates even when an earlier gate fails;
- stores complete logs, result bundles, and a summary under the ignored
  `DerivedData/Perfection/` directory;
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

Valid gate names are `ios-build`, `ios-tests`, `swiftpm-smoke`, `watch-build`,
and `watch-tests`. Use `--list` to print them.

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
a fresh audit before declaring the current revision ready.

## Boundaries

- Do not deploy to, install on, or launch a connected iPhone during a normal
  audit. Device signing is a separate workflow with keychain implications.
- Do not modify simulator state beyond what `xcodebuild` needs for its selected
  destinations.
- Do not clean global Xcode caches or DerivedData. Audit artifacts stay inside
  this repository's ignored `DerivedData/Perfection/` path.
- Do not use the interactive `run.sh`; it installs, launches, and opens the
  Simulator app, which is unnecessary for quality validation.
