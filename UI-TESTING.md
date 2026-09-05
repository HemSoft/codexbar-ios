# Isolated account UI tests

`CodexBarIOSUITests` drives the rendered app with XCTest on iPhone and iPad.
Run both destinations with the active Xcode installation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/run-ui-tests.sh
```

Pass `iphone` or `ipad` to run one family. The runner selects the newest
installed iOS runtime compatible with the active simulator SDK. Set
`UI_TEST_DEVICE_NAME` or `UI_TEST_DEVICE_ID` to choose an available simulator
when running a single family. The default `all` mode rejects these overrides
before launching either destination.
`UI_TEST_RESULTS_DIR` changes the output directory, which defaults to
`build/ui-tests`. Each invocation creates a fresh result directory and retains
the build log, result bundle, and summary. On failure it also exports screenshot
attachments and the accessibility hierarchy from the result bundle. Open the
`.xcresult` in Xcode to inspect each action and assertion.

## Journeys

Both tests start with a new UUID storage namespace and use accessibility text
size 2, English labels, and the US locale.

- `testAccountSetupPersistsGroupAndCredentialAtAccessibilitySize` starts with
  no accounts or groups, adds a group through Settings, opens Add Account,
  chooses OpenRouter, selects its group, and saves a synthetic key.
  It checks the dashboard balance, terminates and relaunches the app in the
  same namespace, then reopens Settings and checks the saved label, selected
  group, and credential availability.
- `testRefreshRecoveryHistoryAndAccountDeepLink` starts with a synthetic
  account and history. It checks a fresh $25 balance, taps Refresh, checks that
  the failed fetch preserves a stale $25 balance, reads the error, and retries
  to obtain a fresh $60 balance. It opens History, selects Today and 7 days,
  checks that the chart's accessible value changes, then delivers an actual
  `codexbar://provider?account=ui-recovery-account` URL while History is open.
  The dashboard must dismiss History and expose the requested account.

The tests assert accessible names, values, selection state, and reachable tap
targets. They cover app-owned account and usage navigation. Live website sign-in,
provider API contracts, and VoiceOver speech remain separate verification.

## Fixture startup and isolation

The DEBUG app accepts `CODEXBAR_UI_TESTS=1` only on a simulator, with a valid
UUID in `CODEXBAR_UI_TEST_RUN_ID`. Invalid IDs fail immediately. This creates
`com.hemsoft.CodexBarIOS.ui-tests.<UUID>`, never an arbitrary defaults domain.
`CODEXBAR_UI_TEST_RESET=1` clears only that namespace; `0` preserves it for
relaunch. `CODEXBAR_UI_TEST_SCENARIO=empty` begins with no accounts, while
`recovery` seeds an account and three history samples. Test runs generate their
own UUIDs, so separate tests and devices cannot reuse each other's state.

The fixture supplies this suite to account configuration, history, app review,
app updates, GitHub preferences, and widget preferences. Its credential store
uses the same suite and accepts only the literal `ui-test-credential`. It never
reads or writes Keychain. Only the synthetic OpenRouter usage provider is
registered. The production account form, group persistence, refresh service,
dashboard, History, and URL handler still execute.

The fixture disables lifecycle polling and bootstrap imports, uses a notifier
that does nothing, and injects widget publishers and a Watch sender that do
nothing. A URLProtocol blocks unexpected URLSession traffic. No credentials,
provider account, Watch pairing, notification permission, or external network
service is needed. DEBUG fixture functions have an explicit exclusion in the
function-risk policy because they are test infrastructure. The production risk
baseline remains unchanged.

## CI and failure reproduction

The existing required `iOS tests` status runs both UI destinations on every
pull request. An always-run gate requires both steps to succeed, even if an
earlier step fails. The runner additionally rejects anything other than two
passed tests with zero skips or expected failures. CI retains both destinations'
result bundles, logs, summaries, and exported failure screenshots for 14 days.
Unit-test coverage and function-risk checks remain in the same required job.

To reproduce a failure, rerun the same family with the command above. Every
journey resets its own storage, so no simulator-wide data wipe is needed.
For a navigation mutation check, make a disposable copy of the repository,
replace the `dismiss()` call inside `AddAccountSetupFlow`'s Done button with an
empty action, and run the iPhone suite there. The setup journey must fail when
it cannot reach the dashboard balance. Keep that mutation out of the PR.
