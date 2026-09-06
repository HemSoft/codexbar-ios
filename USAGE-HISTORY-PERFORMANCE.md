# Usage-history performance budget

Issue [#310](https://github.com/HemSoft/codexbar-ios/issues/310) adds a regression
budget for the existing main-actor history implementation. Production behavior
is unchanged. The budget compares Release binaries built on the same machine
against frozen source revision `3395ee6094ce8e4199577f7ede493e3a50ee1269`.
It does not turn a Mac measurement into an iPhone responsiveness target.

## Run the gate

From the repository root on a Mac with Xcode installed:

```sh
python3 scripts/usage-history-performance/run.py --output /tmp/history-performance
```

The runner selects `/Applications/Xcode.app/Contents/Developer`, builds with
`swift build -c release`, and sets `TZ=UTC`. It archives the baseline commit in a
unique temporary directory, copies the current benchmark source into that
archive, and adds only its executable target to the baseline package manifest.
Both sides exercise the same fixture and public API. No production source,
branch, worktree, or baseline file is rewritten. The temporary archive is
removed on exit; each Swift process removes its unique `UserDefaults` suite.

The output includes build logs, raw JSON for every process, machine/toolchain
metadata, the fixture SHA-256, and `result.json`. An invalid fixture, failed
build, missing measurement, excessive noise, latency regression, or resource
regression exits nonzero. A failed build is not a detected slowdown.
Use a new or empty output directory for every run. The runner rejects old
artifacts so a failed attempt cannot reuse an earlier result as evidence.

For one diagnostic distribution without the comparison gate:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer TZ=UTC \
  xcrun swift run -c release UsageHistoryBenchmark
```

The runner's `--pairs 5` option reproduces the calibration sample count. Ordinary
runs use three pairs. Compilation finishes before any timing begins.

## Workload and measurement

Each process runs 1, 10, and 25 accounts, with two stable Codex usage metrics per
account. Fixed values of 37% and 62%, fixed-width account IDs, and a fixed UTC
anchor make serialized-size comparisons deterministic. The fixtures contain:

- 240 frequent snapshots per account at two-hour intervals, spanning 20 days;
- 90 distinct UTC daily bins with one snapshot per metric, or 180 daily entries
  per account;
- fresh successful results for every account, with a new timestamp on each
  recording call.

The benchmark seeds `usageHistorySnapshots` and `usageHistoryDailySnapshots` in
a UUID-named `UserDefaults` suite. It validates loaded and persisted arrays for
unique IDs, every expected account, per-account counts, both metric identities,
and 90 daily bins. A fresh record replaces the oldest frequent sample and
today's two daily components. All-account chart generation must return one
aggregate usage series with 329 timestamps per account and a 62% value at each
point. This matches the current Codex chart's aggregation of the two metrics.

`ContinuousClock` measures seven batches per operation. The first two are
warmups. All seven values remain in each report; only the remaining five enter
the median. Recording measures one refresh of all accounts, including snapshot
rebuilding, sorting, daily aggregation, JSON encoding, and `UserDefaults.set`.
It does not measure eventual defaults-file durability. Series generation measures
five all-account chart passes per batch and reports milliseconds per pass.
Fixture creation, loading, correctness assertions, and resource inspection sit
outside both timed regions. The measured series results are consumed and checked.

After the timed batches, 32 additional fresh records exercise capped frequent
history, and seven daily rollovers exercise expiry of the oldest daily bin.
Every one of the 47 resource observations must retain 240 frequent and 180 daily
entries per account. The report records the combined encoded byte count from the
two stored defaults values at every observation.

These are retained model and serialized-data budgets. Allocation churn, process
RSS, and allocator caches are not leak evidence. This benchmark does not measure
retained heap objects or declare the app leak-free. Use Instruments with a
repeatable user journey for a separate memory investigation, following Apple's
[heap-memory guidance](https://developer.apple.com/videos/play/wwdc2024/10173/).

## Hardware matrix and failure policy

| Environment | Configuration | Role |
| --- | --- | --- |
| Mac17,4, Apple M5, 16 GiB, macOS 26.5.2 build 25F84, Xcode 26.6 build 17F113, Swift 6.3.3 | SwiftPM Release, arm64 | Committed calibration and disposable slowdown experiment |
| GitHub `macos-26` runner, actual model, architecture, OS, Xcode and Swift captured in each artifact | SwiftPM Release | Relevant pull requests, weekly Monday schedule, and manual dispatch |
| iPhone and iPad simulators in existing CI | Existing Xcode correctness/UI configurations | Correctness coverage, no latency budget |
| Physical iPhone/iPad and watchOS | Not benchmarked here | No inferred performance result or device latency claim |

The workflow `Usage history performance` fails the `Usage history Release budget`
job on any gate failure. It runs on relevant source/tooling pull requests and
weekly at 07:17 UTC on Monday, as well as manual dispatch. It does not alter
branch protection; the weekly job is the selected maintained failure policy.
Existing required correctness checks remain applicable.

Reference and candidate processes run sequentially in alternating order on the
same host. Stop other local builds and heavy foreground work while measuring.
Three paired runs give three ratios of candidate median to reference median;
the median ratio must meet the latency limit. The reference stays pinned across
pull requests, so repeated small changes cannot silently move the baseline.

The gate also checks the coefficient of variation across each side's run
medians. A noisy control or candidate is inconclusive and fails. Within-run CVs
are reported for diagnosis; medians reduce the influence of one or two isolated
outliers among the five retained timings. We do not delete slow samples or retry
until a green run appears. After an inconclusive run, inspect the artifact,
remove competing load, and rerun the whole paired experiment once. Persistent
noise needs investigation before changing the policy. Apple likewise separates
[performance baselines and deviation limits](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests).

## Measured baseline and limits

Calibration on September 6, 2026 at 12:25 a.m. EDT used five alternating pairs,
ten independent processes, and 25 post-warmup samples per operation/account
count on each side. Both production trees were the unchanged frozen revision.
The new benchmark source hash and all seven samples from every process are
committed in `scripts/usage-history-performance/calibration.json`. Its original
measurement policy is recorded separately from the subsequently adopted limits.
Re-evaluating those samples against the adopted policy passes.

The local calibration truthfully records `candidateDirty: true`: the new
benchmark, manifest entry, and documentation were uncommitted then. All
`CodexBarIOS` production sources matched the frozen revision, as checked before
the run and independently confirmed from the committed change:

```sh
git diff --exit-code 3395ee6094ce8e4199577f7ede493e3a50ee1269 \
  ea8eb7baec0e459f0403eb0d07b0fc01e4f21602 -- CodexBarIOS
```

The recorded benchmark SHA-256 identifies the benchmark source copied into both
builds. This is verified source equivalence for the measured workload, not a
claim of bit-identical binaries. The later [cold hosted run](https://github.com/HemSoft/codexbar-ios/actions/runs/34011866772)
used a clean checkout and passed on Apple M1 Virtual hardware with Xcode 26.6.
Its job took 4 minutes 50 seconds, including 54.11-second and 42.86-second Release
builds, within the 20-minute timeout.

The current benchmark explicitly casts the bounded account numbers to `Int32`
for `%02d`. This formatting correction sits outside the timed operations and
preserves all account IDs, fixture values, series work, and retained-data output.
The historical source hashes and timing observations remain unchanged.

| Accounts | Reference recording median, ms | Reference all-account series median, ms | Retained serialized bytes |
| ---: | ---: | ---: | ---: |
| 1 | 4.010 | 1.018 | 218,162 |
| 10 | 40.006 | 12.384 | 2,181,602 |
| 25 | 90.004 | 38.697 | 5,454,002 |

The latency columns are medians of the five process medians. They are diagnostic
Mac measurements, including JSON encoding and `UserDefaults.set`, not iPhone goals.
The largest median candidate/reference ratio was 1.0265. The largest individual
pair ratio was 1.0459, and the largest between-run CV was 8.06%. One recording
distribution had a 26.54% within-run CV; its full samples remain in the evidence.
The paired medians handled that observed burst without discarding it.

The maintained limits are:

- A median latency ratio of at most **1.25** for each operation and account
  count. This allows a 25% increase, over five times the largest observed
  positive paired deviation of 4.59%, while catching a sustained slowdown.
- A between-run CV of at most **15%** on both sides, below twice the largest
  measured control variation. Beyond this, the experiment cannot establish a
  pass. This is a measurement-quality threshold, not a latency allowance.
- Candidate serialized size no larger than the same-host reference maximum,
  with **zero bytes of positive steady-state growth** after warmup. All 47
  observations in every calibration process had exactly the sizes above.
  Constant-width values and timestamps, fixed per-account counts, and the
  canonical daily representation justify an exact retained-data budget.
  A deliberate persisted-schema expansion therefore needs reviewed evidence.

These thresholds are an initial measured regression policy. They are not a
claim that 90 ms of main-actor work is a good device experience. Device profiling
can inform a later optimization issue without changing this measurement-only
scope.

## Baseline maintenance

`scripts/usage-history-performance/baseline.json` owns the immutable revision
and limits. `calibration.json` next to it records the measured evidence. Schema
or fixture changes need a fresh calibration on both sides and review of expected
counts/series output. Toolchain changes compile both revisions with that same
toolchain, and retain the actual version in the report.

Change the frozen revision or resource limits only in an issue-linked PR that
explains the accepted behavior or cost, commits new raw distributions and
hardware metadata, and repeats the slowdown proof. Do not raise a limit merely
to make a regression green. A public API change that prevents the frozen source
from compiling is an explicit baseline maintenance task, not permission to skip
the gate.

The committed calibration and slowdown records declare the
`uniform-retained-state-v1` format. Each scenario stores all seven raw timings
for both operations. Its 47 byte-for-byte equal retained-state observations are
stored once as `retainedState` with `retainedObservationCount: 47`. This is
lossless compression of the observed records, not the runtime report schema.
Runtime artifacts retain the full `retainedStates` array.

Replay the committed evidence without rebuilding or taking new measurements:

```sh
python3 scripts/usage-history-performance/replay.py
```

The replay tool validates the declared format, expands every observed state,
then passes the reconstructed reports through the ordinary `validate` and
`evaluate` functions with the current policy. It must report calibration PASS
and recording regressions for all three account counts in the slowdown proof,
without noise findings. The policy tests exercise this path and reject invalid
compressed records. The original timing, hash, and dirty-state metadata are
preserved as historical measurements.

## Prove slowdown detection

```sh
python3 scripts/usage-history-performance/run.py \
  --output /tmp/history-slowdown --prove-slowdown
```

This deliberately returns exit status 1. It inserts a 120 ms synchronous delay
inside `UsageHistoryStore.record` in the disposable baseline archive, builds that
candidate, then runs the ordinary paired gate against the untouched reference
binary. The normal checkout is unchanged. Count this as successful detection
only when `result.json` exists, `passed` is false, the findings include recording
`REGRESSION` results, and there are no `INCONCLUSIVE` findings. A compiler error,
fixture assertion, or infrastructure failure does not prove detection.

The deterministic failure-policy checks also run in the workflow:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_usage_history_performance.py' -v
```

The September 6, 2026 experiment completed all three paired runs and returned
status 1 with recording regressions at 1, 10, and 25 accounts, respectively
34.846x, 4.480x, and 2.543x. The one-account series measurement also exceeded the
budget, at 2.331x.
There were no inconclusive/noise findings. All fixture assertions and retained
budgets passed. `scripts/usage-history-performance/slowdown-proof.json` preserves
the complete timing distributions, metadata, and ordinary gate findings.
