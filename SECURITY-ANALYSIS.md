# Swift security analysis

The `Swift security analysis` check builds and analyzes the iOS app, its widget,
the embedded watch app, and its complication. It runs on every pull request,
every push to `main`, and Mondays at 08:23 UTC (04:23 EDT / 03:23 EST). Maintainers
can also run the `Swift security` workflow manually.

## Analyzer and source reach

The workflow pins CodeQL Action 4.37.9 to a commit and the CodeQL bundle to
2.26.4. That bundle includes `codeql/swift-queries` 1.3.9 and `codeql/swift-all`
6.8.2. It runs the `security-extended` suite, including the default security
queries. No security queries or production paths are excluded.

The [CodeQL support matrix](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/)
covers Swift 5.4-6.3. [CodeQL 2.26.2 added Swift 6.3.3 extraction](https://codeql.github.com/docs/codeql-overview/codeql-changelog/codeql-cli-2.26.2/),
which matches this repository's Xcode 26.6 compiler at setup. The check records
the actual Xcode, Swift, and CodeQL versions on every run; an unsupported upgrade
must produce working extraction evidence before merging a toolchain change.

Swift requires a [traced build](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages).
`scripts/security-analysis/build.sh` uses a new Derived Data directory and the
`CodexBarIOS` scheme with the Debug simulator configuration and one architecture.
The scheme builds all four production targets. This includes authentication,
provider networking, credential and history persistence, and `CodexBarIOS/Shared`.
Debug also includes the isolated UI-test fixture support in the app source tree.

An evidence-only CodeQL query counts extracted syntax nodes and compiler errors
for each Swift file. The gate requires syntax for every tracked `.swift` file in
`CodexBarIOS`, `CodexBarIOSWidget`, `CodexBarWatch`, and `CodexBarWatchWidget`.
Adding a file without adding it to a build target fails this coverage check.
Compiler errors also fail even if the rest of the file extracted. The CSV is
included in the run artifact. A source archive alone is not coverage evidence.

Unit tests, UI test targets, the smoke executable, and development scripts are
outside the production scope; they are covered by the normal CI checks. Imported
SDK/dependency declarations may appear in the database but are not counted as
repository production files. Conditional branches inactive for the selected
simulator platforms are not analyzed. These file counts do not prove that every
possible data flow, platform branch, or runtime vulnerability was checked.

## Findings and merge gate

The check uploads SARIF to the repository's **Security > Code scanning** page
under category `swift-production`, waits for processing, and retains SARIF,
compiler versions, extracted-source counts, and `gate.json` as an Actions
artifact for 14 days. The job has only `contents: read` and
`security-events: write`; checkout does not persist credentials. Pull requests
use `pull_request`, never privileged `pull_request_target` execution.

`scripts/security-analysis/gate.py` fails on any security severity of 7.0 or
higher, including existing or suppressed findings. Lower-severity findings are
still published for triage. Missing, failed, or malformed analysis, empty query
metadata, incomplete source reach, and extraction errors also fail the job.
There are no accepted high-severity findings or automatic baseline refreshes.
Fix the cause rather than dismissing an alert to bypass the check.

Repository rules must require the GitHub Actions check `Swift security analysis`
alongside the existing required checks. The workflow alone does not change
repository rules. When changing the check name, update the rule in the same
rollout so the old required name does not leave pull requests waiting forever.

## Initial baseline

Before issue #309, the code-scanning API returned `no analysis found`. That was
missing evidence, not a clean baseline. The first complete production analysis,
its findings, extraction counts, and run URL will be recorded here after the
workflow completes. No exclusions have been added while results are pending.

To inspect a completed analysis, use both APIs, checking its analyzed commit and
`error` field before interpreting an empty alert list:

```sh
gh api 'repos/HemSoft/codexbar-ios/code-scanning/analyses?per_page=20'
gh api 'repos/HemSoft/codexbar-ios/code-scanning/alerts?state=open'
```

Pull-request analysis normally records GitHub's test merge SHA and
`refs/pull/<number>/merge`, rather than the branch head SHA. Match that merge SHA
to the workflow run; do not claim it analyzed a different commit.

## Reproduce the positive test

The temporary fixture `scripts/security-analysis/fixtures/Positive.swift`
configures TLS 1.0 in an uncalled function. It creates no network request and uses
no credentials. `build.sh` compiles the fixture separately when it exists; it
never links the fixture into a production target. CodeQL's
[`swift/insecure-tls`](https://codeql.github.com/codeql-query-help/swift/swift-insecure-tls/)
query has security severity 7.5 and must fail the same required job.

For future analyzer upgrades, add this fixture on an issue branch, observe the
authentic finding and failed `Swift security analysis` status, then remove it
and require the next analysis to pass:

```swift
import Foundation

func insecureTLSPositiveFixture() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
    return configuration
}
```

Gate parser failure tests run with:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_security_analysis.py' -v
```

Those tests use synthetic parser inputs. They do not replace the real CodeQL
positive test or prove analyzer reach.

For local extraction with the pinned CodeQL bundle on a supported Mac:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SECURITY_DERIVED_DATA="$(mktemp -d)/DerivedData"
codeql database create /tmp/codexbar-security-db --language=swift \
  --source-root=. --command=./scripts/security-analysis/build.sh
codeql database analyze /tmp/codexbar-security-db \
  codeql/swift-queries:codeql-suites/swift-security-extended.qls \
  --format=sarif-latest --output=/tmp/codexbar-security.sarif
codeql query run scripts/security-analysis/queries/source-reach.ql \
  --database=/tmp/codexbar-security-db --output=/tmp/codexbar-reach.bqrs
codeql bqrs decode /tmp/codexbar-reach.bqrs --format=csv --output=/tmp/codexbar-reach.csv
python3 scripts/security-analysis/gate.py --sarif /tmp/codexbar-security.sarif \
  --reach /tmp/codexbar-reach.csv --output /tmp/codexbar-security-gate.json
```

Use unused database/build paths. Some local Macs cannot execute the tracer's
copied system shell; `Bad CPU type in executable` is an extraction failure, not
a finding-free scan. The hosted workflow remains the required evidence.
