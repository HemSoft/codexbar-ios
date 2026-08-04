# CodexBar iOS Agent Notes

CodexBar for iOS is a native SwiftUI companion app (bundle ID
`com.hemsoft.CodexBarIOS`, scheme `CodexBarIOS`, Xcode project
`CodexBarIOS.xcodeproj`). Xcode targets: `CodexBarIOS` (app),
`CodexBarIOSWidget` (widget), `CodexBarIOSTests` (unit tests),
`CodexBarWatch` (embedded watchOS 10 companion), `CodexBarWatchWidget`
(WidgetKit complication extension), and `CodexBarWatchTests` (watchOS unit
tests). Shared schemes are `CodexBarIOS`, `CodexBarWatch`, and
`CodexBarWatchTests`. `Package.swift` also exposes the
`CodexBarIOSSmokeTests` executable smoke harness. See
`README.md` for scope and the Windows reference repo, `APP-STORE.md` for store
metadata, `PRIVACY.md` for the privacy policy, `SUPPORT.md` for support flow,
and `CHANGELOG.md` for release history.

This file is a standing reference for agents working in this repo. Date-specific
facts (incident dates, snapshot UUIDs, certificate fingerprints) are noted as
such and may be stale — re-verify before relying on them.

## Contents

- [Required Issue-First Workflow](#required-issue-first-workflow)
- [Changelog and Release History](#changelog-and-release-history)
- [Build and Test](#build-and-test)
- [Pull Request Reviewers](#pull-request-reviewers)
- [Connected iPhone and Signing](#connected-iphone-and-signing)
- [Browser Auth Takeaways](#browser-auth-takeaways)

## Required Issue-First Workflow

Every repository change must begin with a GitHub issue. This requirement applies
to code, documentation, configuration, build, and process changes, including
changes to this `AGENTS.md` file.

On intake of a repository-change request, create or identify its defining issue.
Unless the user explicitly requests same-turn implementation, end the turn after
that issue step; do not create a branch, edit files, run implementation tests,
open a pull request, or begin implementation in that same turn.

Before editing files:

1. Create or identify the GitHub issue that defines the change. If a request
   arrives without an existing issue, create one before making any edit.
2. Keep the `main` worktree clean and synchronize `main` with `origin/main`.
   Never make implementation changes directly on `main`, and never leave
   uncommitted implementation work there.
3. Create an issue-specific branch from the synchronized default branch and
   reference the issue in the branch and pull-request workflow.
4. Deliver the change through a pull request that links the issue and is the
   only path for returning the work to `main`.

## Changelog and Release History

`CHANGELOG.md` is the source of truth for CodexBar release history. Maintaining
it is part of completing a change, not a cleanup task for the end of a release.
The history is used to prepare App Store **What's New** text, release notes,
support responses, launch announcements, and other marketing material, so it
must remain accurate, readable, and useful to people outside the codebase.

`CHANGELOG.md` follows a Keep a Changelog–style layout: a top-level heading per
version (`## <version> - <date>`), with `### Added`, `### Changed`, `### Fixed`,
and a separate `### Developer Experience` subsection for build, signing, and
release-process changes so they do not leak into App Store copy. Reference
GitHub issues with `([#NN](https://github.com/HemSoft/codexbar-ios/issues/NN))`
when they add useful context.

- Update the current `Unreleased` version in the same branch or PR as every
  user-visible addition, change, fix, or removal.
- Describe the user benefit and observable behavior. Avoid implementation-only
  language in customer-facing sections.
- Keep development, build, signing, and release-process changes under the
  separate `Developer Experience` heading so they do not leak into App Store
  copy.
- Link the relevant GitHub issue when it provides useful context, and make sure
  the changelog never promises work that is only planned or still incomplete.
- Preserve published version sections as historical records. Do not rewrite or
  remove released entries except to correct a factual error.
- Before an App Store submission, replace `Unreleased` with the release date,
  verify the section matches the shipped `MARKETING_VERSION` (set in
  `CodexBarIOS.xcodeproj/project.pbxproj`), and derive the App Store and
  marketing copy from those verified entries.
- After cutting a release, start the next version's `Unreleased` section before
  additional product work lands. Do not reconstruct release history from git
  commits at the last minute.

## Build and Test

Use Xcode explicitly; the active `xcode-select` path may point at Command Line
Tools, so prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- Build for the simulator (also boots, installs, and launches an iPhone 17
  simulator): `./run.sh`
- Plain simulator build without install/launch:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarIOS \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build
  ```

- Run unit tests (`CodexBarIOSTests`):

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarIOS \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test
  ```

- Run the SwiftPM smoke harness:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift run \
    CodexBarIOSSmokeTests
  ```

- Run the canonical repository-wide lint gate with the exact
  `SwiftLintPlugins` version resolved by Swift Package Manager:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift package \
    plugin --allow-writing-to-package-directory swiftlint lint \
    --reporter xcode .
  ```

  The root `.swiftlint.yml` uses strict mode, so every warning fails this
  command. The same pinned build-tool plugin runs automatically for every
  Swift-producing iOS, watchOS, widget, test, and SwiftPM target. Xcode may ask
  developers to trust the package plugin on first use; unattended builds can
  pass `-skipPackagePluginValidation` after reviewing the pinned dependency.

- Build the watchOS 10 companion shell on a simulator compatible with the
  active Xcode toolchain. Run these commands from the repository root:

  ```sh
  watch_device_id="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./scripts/select-watch-simulator.sh)"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarWatch \
    -destination "platform=watchOS Simulator,id=$watch_device_id" \
    build
  ```

- Run the watch foundation tests using the same compatible destination:

  ```sh
  watch_device_id="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./scripts/select-watch-simulator.sh)"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project CodexBarIOS.xcodeproj -scheme CodexBarWatchTests \
    -destination "platform=watchOS Simulator,id=$watch_device_id" \
    test
  ```

The selector chooses the newest installed watchOS runtime that is not newer
than the active `watchsimulator` SDK, then chooses a device reproducibly. If no
compatible device exists, it prints the active SDK plus the available runtimes
and devices before failing. The watch app is a dependent companion embedded in
`CodexBarIOS` and includes a WidgetKit complication extension driven by usage
snapshots from the iPhone. It does not enable independent installation,
credentials, or provider networking.

There is no separate typecheck tool beyond Xcode/Swift compiler warnings and
the test targets above.

## Pull Request Reviewers

This repository has three automated PR reviewers. Treat all of them as part of
the normal merge-readiness loop: triage actionable feedback, fix or document
each thread, explicitly resolve addressed review threads in GitHub, and request
fresh reviews after meaningful updates.

| Reviewer | GitHub identity / check | Trigger | Auto on push? |
| --- | --- | --- | --- |
| Codex | `chatgpt-codex-connector` | `@codex review` on the PR, or automatic Codex cloud reviews when enabled | When enabled in Codex cloud settings |
| CodeRabbit | `coderabbitai` / `CodeRabbit` check | `@coderabbitai review` on the PR | Configurable per repo in CodeRabbit |
| Cursor Bugbot | `cursor` / `Cursor Bugbot` check | `cursor review` or `bugbot run` on the PR, or automatic Bugbot reviews when enabled in the Cursor dashboard | When enabled in the Cursor dashboard |

The expected CI checks that must pass for merge are whatever the repo's branch
protection requires; re-check the current required-checks list in GitHub rather
than assuming the three reviewers above are sufficient.

Notes for agents:

- Request Codex and CodeRabbit through PR trigger comments, not the Copilot
  `requestReviewsByLogin` API path.
- Bugbot is configured on this repo through the Cursor GitHub app. Prefer
  `cursor review` when requesting a manual rerun.
- None of these reviewers is a guaranteed branch-protection approval by itself.
  Report the actual GitHub review/check state for the current head SHA.
- Before declaring a PR ready, confirm actionable threads from all reviewers
  that left feedback are addressed and explicitly resolved, and that normal PR
  checks pass for the current head.

Example manual review requests on a PR:

```text
@codex review
@coderabbitai review
cursor review
```

## Connected iPhone and Signing

Use [DEVICE-DEPLOYMENT.md](DEVICE-DEPLOYMENT.md) for the complete connected
iPhone build, install, launch, verification, and signing-recovery runbook.
Always discover the current device ID and build-products path; do not reuse
recorded snapshot identifiers.

Signing safety rules:

- Use `~/Library/Keychains/codexbar-dev.keychain-db`, never the crowded login
  keychain, for device-build signing.
- Never ask for, print, or store the signing-keychain password in chat or
  repository files. Its owner-only local password file must stay outside the
  login keychain.
- Keep `codexbar-dev.keychain-db` out of the normal keychain search list and
  keep `login.keychain-db` as the default keychain.
- Run signing commands through `./scripts/with-codexbar-keychain.sh`; first try
  `./scripts/unlock-codexbar-keychain.sh` after a reboot.
- Verify the live identity with `security find-identity` before acting. Do not
  treat a recorded certificate fingerprint as current, delete identities
  repeatedly, or reset the keychain unless the dedicated keychain is unusable.
- Use `./scripts/reset-codexbar-keychain.sh` only for the recovery case described
  in the runbook. It backs up the old keychain before recreating it.

## Browser Auth Takeaways

- For browser-based provider auth (e.g. Claude), search that provider's current
  public docs/issues before changing the flow. Claude Code currently expects a
  localhost callback style such as `http://localhost:<port>/callback`.
- Start the local callback listener before opening Safari/`ASWebAuthenticationSession`, and keep the exact redirect URI consistent between authorize and token exchange.
- Browser-session providers should only become configured after their secret/token is saved. A suggested account label is not proof of auth.
- If auth appears to succeed but the provider is missing from settings/dashboard, check `ProviderConfigurationStore.isConfigurationReady`, `hasSecret`, account-specific keychain IDs, and status text first.
- After auth or signing changes, run simulator tests, then build/install/launch on the connected iPhone with `devicectl`.
