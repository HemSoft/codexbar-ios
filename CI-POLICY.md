# CI gate and manual analysis policy

The automatic merge gate retains SwiftLint, Strict concurrency, iOS tests,
watchOS tests and SwiftPM smoke tests. The required `iOS tests` job runs unit
tests, coverage, and function-risk enforcement without UI journeys. The full
iPhone and iPad UI gate, Swift security analysis, and the usage-history Release
budget run manually with their failure rules and artifacts preserved.

This policy revises the decision in
[issue #325](https://github.com/HemSoft/codexbar-ios/issues/325), which kept both
UI destinations in every pull-request run. The measured cost prompted
[issue #337](https://github.com/HemSoft/codexbar-ios/issues/337) to move them to
manual dispatch.

## Rollout status

The live `main required quality checks` ruleset requires the five automatic
checks above, with strict branch freshness and no bypass actors. Those status
names do not change under issue #337, and `Full iOS UI validation` is not a
required status. No ruleset mutation is needed for this policy change. Classic
branch protection returns 404 because the repository ruleset supplies the
requirements.

The `CI` workflow handles pull requests, pushes to `main`, and manual dispatch.
Only manual dispatch can start `Full iOS UI validation`, and that job waits for
the five automatic jobs to pass. The security-analysis and usage-history
performance workflow files contain only `workflow_dispatch`.

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

| Job | Successes / total | Median | P90 | Longest success | Timeout at inventory |
| --- | ---: | ---: | ---: | ---: | ---: |
| SwiftLint | 62 / 63 | 40s | 49s | 54s | 10m |
| Strict concurrency | 56 / 63 | 4m 03s | 5m 13s | 6m 16s | 30m |
| iOS tests | 28 / 63 | 18m 42s | 40m 08s | 49m 34s | 50m |
| watchOS tests | 55 / 63 | 4m 45s | 6m 32s | 7m 04s | 30m |
| SwiftPM smoke tests | 60 / 63 | 1m 08s | 1m 22s | 1m 29s | 15m |
| Swift security analysis | 9 / 25 | 31m 09s | 39m 52s | 39m 52s | 60m |
| Usage history Release budget | 5 / 8 | 5m 01s | 5m 25s | 5m 25s | 20m |

A later successful [CI run on September 10,
2026](https://github.com/HemSoft/codexbar-ios/actions/runs/34459470256)
took 52m 10s and consumed 61.9 summed macOS job-minutes. Its iOS job used
51m 07s, including 12m 24s for unit tests, 19m 32s for iPhone UI journeys, and
17m 21s for iPad UI journeys. This completed-run sample supplied the cost basis
for issue #337.

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

The Release budget's three failed workflow runs produced four retained failed
attempts, including a rerun. All four artifacts report only inconclusive noise
findings, with no latency or retained-data regression. Their failed step was
the paired comparison. The
[latest noisy result](https://github.com/HemSoft/codexbar-ios/actions/runs/34054447047/job/101543620434)
had a 20.06% run CV for one-account recording and 16.90% for 25-account series
generation, exceeding the unchanged 15% limit. Its six median latency ratios
were between 0.831 and 1.091, with no latency or retained-data regression.
The artifact establishes an inconclusive measurement, not a regression or a
specific cause. Its machine metadata does not contain process-by-process load
or thermal observations.

## Automatic gate budget

Keep the five required status names. They check lint, strict concurrency, iOS
unit behavior and function risk, watchOS behavior and function risk, and the
SwiftPM smoke harness. The automatic `iOS tests` job has a 30-minute limit. The
other four automatic timeouts remain unchanged.

The historical table predates the UI split and must not be used as the measured
post-change duration. In the September 10 sample, the two UI destinations used
36m 53s of the run's 61.9 summed macOS job-minutes. Removing those steps from
ordinary PR runs avoids that work. Record completed post-change runs before
claiming the actual savings. The concurrency policy cancels obsolete runs, but
it cannot recover runner time spent before cancellation.

The manual full gate retains a 90-minute limit for `Full iOS UI validation`.
Keeping the UI suites intact preserves their correctness decisions without
charging every review-fix commit for both simulator families. Inspect unit
tests, simulator startup, each UI family, and artifact steps separately when a
manual run is slow.

Security's 31-minute median and incomplete 60-minute attempt justify a
separate manual job. Retain its 60-minute cap. Performance remains manual
because measurement noise can prevent a usable decision, even though its
successful runs took about five minutes. Retain its 20-minute cap and all
current thresholds.

## Manual runs and failure ownership

Run the full CI gate for release preparation and for changes to navigation,
account setup, dashboard flows, accessibility behavior, UI fixtures, or UI-test
infrastructure. The dispatch first runs the five automatic jobs. If they pass,
`Full iOS UI validation` runs all five journeys on both iPhone and iPad. A
failed iPhone family does not suppress the iPad family or the retained failure
artifacts.

Run security analysis for authentication, networking, credential storage,
analyzer or toolchain changes, and release preparation. Run the Release budget
for history persistence, chart generation, benchmark or toolchain changes, and
release preparation. The maintainer requesting any manual run owns inspecting
its result and recording its disposition in the related issue or PR. A green
automatic gate does not imply a manual gate ran.

Choose a branch or tag whose resolved commit has been reviewed. Record the
resolved SHA immediately before dispatch and confirm the run's `headSha` after
dispatch. A branch can move between those operations.

```bash
set -euo pipefail
reviewed_ref=<reviewed-branch-or-tag>
encoded_ref="$(jq -rn --arg ref "$reviewed_ref" '$ref|@uri')"
reviewed_sha="$(gh api \
  "repos/HemSoft/codexbar-ios/commits/$encoded_ref" --jq '.sha')"

gh workflow run ci.yml --repo HemSoft/codexbar-ios --ref "$reviewed_ref"
gh workflow run security-analysis.yml --repo HemSoft/codexbar-ios --ref "$reviewed_ref"
gh workflow run usage-history-performance.yml --repo HemSoft/codexbar-ios --ref "$reviewed_ref"

gh run view <run-id> --repo HemSoft/codexbar-ios \
  --json headSha,event,status,conclusion,url,jobs
gh run download <run-id> --repo HemSoft/codexbar-ios \
  --dir <new-evidence-directory>
```

Compare the reported `headSha` with `$reviewed_sha`. Record a manual full gate
as passed, failed, or not run. Never present an unrun gate as passing. UI result
bundles, logs, summaries, and failure screenshots expire after 14 days.

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
python3 -m unittest discover -s scripts/tests -p 'test_ci_policy.py' -v
gh api repos/HemSoft/codexbar-ios/rules/branches/main
gh api repos/HemSoft/codexbar-ios/branches/main/protection
gh run list --repo HemSoft/codexbar-ios --limit 100 \
  --json databaseId,workflowName,event,conclusion,createdAt,startedAt,updatedAt,url
gh api 'repos/HemSoft/codexbar-ios/actions/runs/<run-id>/jobs?per_page=100&filter=latest'
```

Inspect all pages when more than 100 jobs or annotations exist. Compute job
duration from each job's own start and completion timestamps, not the
workflow's last update time. Confirm an ordinary PR run marks `Full iOS UI
validation` skipped and spends no time in either UI destination. Confirm a
manual `CI` run records `workflow_dispatch`, matches the reviewed SHA, and runs
both destinations after the automatic jobs pass. The security-analysis and
usage-history performance workflows must contain only `workflow_dispatch`.
Keep failures and cancellations in the inventory when refreshing measurements.
