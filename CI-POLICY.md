# CI gate and manual analysis policy

The automatic merge gate retains SwiftLint, Strict concurrency, iOS tests,
watchOS tests and SwiftPM smoke tests. Swift security analysis and the
usage-history Release budget run manually, with their failure rules and
artifacts preserved. This is the policy selected in
[issue #325](https://github.com/HemSoft/codexbar-ios/issues/325).

## Rollout status

The live `main required quality checks` ruleset was changed on September 6,
2026 at 5:13 p.m. EDT. It requires the five correctness checks above, with
strict branch freshness and no bypass actors. Classic branch protection
returns 404; the repository ruleset supplies these requirements.

The two workflow files in this change contain only `workflow_dispatch`.
Their trigger edits match the earlier edits in
[PR #320](https://github.com/HemSoft/codexbar-ios/pull/320), which is still open
at this inventory snapshot. This issue's PR carries the same policy without
changing that Google-metrics PR. Default-branch workflow files still contain
automatic analysis triggers until either change lands. The live rule change
alone does not complete issue #325. Benchmark repeatability, manual dispatch
evidence and verification of the final merged gate remain separate criteria.

## Measured inventory

The snapshot covers the latest 100 workflow runs, September 1, 2026 at
4:47 a.m. through September 6 at 5:13 p.m. EDT. The
[workflow records](docs/ci/2026-09-06-runs.csv) retain all 100 runs, including
four cancelled runs that created no jobs. The snapshot contains 348 jobs from
the latest attempt of each remaining run. The
[job records](docs/ci/2026-09-06-jobs.csv) retain every outcome, source commit,
event, timestamp and job URL. The
[computed summary](docs/ci/2026-09-06-summary.json) records selection and
aggregation rules. This is a development-period sample, not an estimate of
the failure probability of unchanged code.

Durations below use successful completed jobs only and exclude queue time.
P90 is the nearest-rank percentile. Failures, cancellations and the one
unfinished iOS job are retained in the outcome counts, not treated as passes
or silently excluded from the inventory.

| Job | Successes / total | Median | P90 | Longest success | Current timeout |
| --- | ---: | ---: | ---: | ---: | ---: |
| SwiftLint | 62 / 63 | 40s | 49s | 54s | 10m |
| Strict concurrency | 56 / 63 | 4m 03s | 5m 13s | 6m 16s | 30m |
| iOS tests | 28 / 63 | 18m 42s | 40m 08s | 49m 34s | 50m |
| watchOS tests | 55 / 63 | 4m 45s | 6m 32s | 7m 04s | 30m |
| SwiftPM smoke tests | 60 / 63 | 1m 08s | 1m 22s | 1m 29s | 15m |
| Swift security analysis | 9 / 25 | 31m 09s | 39m 52s | 39m 52s | 60m |
| Usage history Release budget | 5 / 8 | 5m 01s | 5m 25s | 5m 25s | 20m |

All 54 cancelled jobs have an explanatory GitHub annotation. Fifty-three
were superseded by a newer request, and one was the
[security extraction timeout](https://github.com/HemSoft/codexbar-ios/actions/runs/34054447013/job/101543699257).
The timeout reached the 60-minute execution limit before analysis and the
findings gate ran. It supplies no security result. Superseded jobs are not
evidence of flaky tests.

The eight iOS failures occurred in two unit-test steps, one iPhone UI step
and five iPad UI steps. The required destination aggregator correctly failed
the six UI cases. There were no annotated iOS timeouts in this snapshot.
Raw logs include simulator launch/background-assertion failures, such as
[this unit-test run](https://github.com/HemSoft/codexbar-ios/actions/runs/33957762004)
and [this UI run](https://github.com/HemSoft/codexbar-ios/actions/runs/34010249721),
as well as actual UI assertions, including
[an unreachable accessibility-size control](https://github.com/HemSoft/codexbar-ios/actions/runs/33989302706).
Job-level outcomes alone therefore cannot separate simulator reliability from
application or test defects. These failures warrant diagnosis, not an automatic
rerun policy or removal of the checks.
The six security failures include extraction/setup and findings-gate failures
during development; they must not all be classified as infrastructure noise.
The single strict-concurrency failure occurred in its compiler-check step.

The Release budget's three failures all occurred in the paired comparison
step. The
[latest noisy result](https://github.com/HemSoft/codexbar-ios/actions/runs/34054447047/job/101543620434)
had a 20.06% run CV for one-account recording and 16.90% for 25-account series
generation, exceeding the unchanged 15% limit. Its six median latency ratios
were between 0.831 and 1.091, with no latency or retained-data regression.
The artifact establishes an inconclusive measurement, not a regression or a
specific cause. Its machine metadata does not contain process-by-process load
or thermal observations.

## Automatic gate budget

Keep the current five required jobs and their timeouts. They check compilation,
lint, concurrency, unit behavior, both UI device families and function-risk
policy. These checks produce correctness decisions that timing measurements
cannot replace. Do not remove iOS tests because it is the slowest required job.

The current execution budget is 50 minutes for the slowest parallel job, plus
runner queue time. The observed longest passing iOS job was 49m 34s, so there
is little headroom. This is a cancellation bound, not a guaranteed turnaround.
Do not promise a sub-30-minute gate: the observed iOS P90 exceeds 40 minutes.
The other four checks normally finish within eight minutes in this sample.
Their existing cancellation limits are retained; this change does not raise
a timeout to hide a regression or lower one without cold-build evidence.

For slow iOS runs, inspect unit tests, simulator startup, each UI family and
artifact steps separately. Preserve both device-family checks and risk gates
when investigating duration. A later runtime reduction needs measured before
and after evidence. Supersession during active revisions is expected because
the CI concurrency policy cancels obsolete work.

Security's 31-minute median and incomplete 60-minute attempt justify a
separate manual job. Retain its 60-minute cap; increasing it is not part of
this policy. Performance is manual primarily because measurement noise can
prevent a usable decision, even though its successful runs took about five
minutes. Retain its 20-minute cap and all current thresholds.

## Manual runs and failure ownership

Run security analysis for authentication, networking, credential storage,
analyzer/toolchain changes and release preparation. Run the Release budget for
history persistence, chart generation, benchmark/toolchain changes and release
preparation. The maintainer requesting each run owns inspecting the result and
recording its disposition in the related issue or PR. A green correctness gate
does not imply either manual analysis ran.

Choose a branch or tag whose resolved commit has been reviewed. Record the
resolved SHA immediately before dispatch and confirm the run's `headSha` after
dispatch; a branch can move between those operations.

```sh
gh workflow run security-analysis.yml --repo HemSoft/codexbar-ios --ref <reviewed-ref>
gh workflow run usage-history-performance.yml --repo HemSoft/codexbar-ios --ref <reviewed-ref>
gh run view <run-id> --repo HemSoft/codexbar-ios --json headSha,event,status,conclusion,url,jobs
gh run download <run-id> --repo HemSoft/codexbar-ios --dir <new-evidence-directory>
```

For security, inspect complete production source reach, compiler/extraction
diagnostics, raw SARIF, reviewed findings and blockers in `gate.json`. Preserve
the distinction between three reviewed findings and zero findings. Artifacts
expire after 14 days. Copy needed release evidence before expiry. A missing
report, timeout, stale baseline or unreviewed high-severity finding requires a
recorded investigation. Refresh a reviewed baseline only through the source
and finding review defined in [SECURITY-ANALYSIS.md](SECURITY-ANALYSIS.md).

For performance, inspect raw reference/candidate samples, machine and toolchain
metadata, fixture identity, run order and every finding in `result.json`.
Artifacts expire after 30 days. Report regression, inconclusive measurement and
execution failure separately. Preserve slow samples. Do not relax the 1.25
latency ratio, 15% CV or retained-data limits to obtain a pass. Follow
[USAGE-HISTORY-PERFORMANCE.md](USAGE-HISTORY-PERFORMANCE.md) for independent
paired experiments and the intentional-slowdown proof.

A confirmed security or performance regression remains actionable after moving
analysis outside branch protection. The requesting maintainer owns the fix or
an explicit documented disposition before the affected release. If discovered
after merge, record the affected commit and choose a corrective PR or revert;
do not turn an incomplete run into release evidence. Manual runs are not a
substitute for the required correctness checks, and pending manual evidence
must remain visible in issue #325 until its criteria are met.

## Recheck the policy

```sh
gh api repos/HemSoft/codexbar-ios/rules/branches/main
gh api repos/HemSoft/codexbar-ios/branches/main/protection
gh run list --repo HemSoft/codexbar-ios --limit 100 \
  --json databaseId,workflowName,event,conclusion,createdAt,startedAt,updatedAt,url
gh api 'repos/HemSoft/codexbar-ios/actions/runs/<run-id>/jobs?per_page=100&filter=latest'
```

Inspect all pages when more than 100 jobs or annotations exist. Compute job
duration from its own start and completion timestamps, not the workflow's last
update time. Confirm both expensive workflow files contain only
`workflow_dispatch` and that an ordinary PR push creates neither analysis run.
Keep failures and cancellations in the inventory when refreshing measurements.
