# Branch rulesets policy

[AGENTS.md](AGENTS.md) requires every repository change to reach `main` through
an issue-linked pull request with resolved review conversations. The live
default-branch ruleset enforces the pull-request and resolved-conversation
portions of that path on the server. It cannot validate issue linkage, so that
part stays an agent-workflow requirement. This file documents the live rules,
the review-count policy, who can change the rules, and how to apply and verify
a change.

## Live ruleset

`main required quality checks` (ruleset [20103668](https://github.com/HemSoft/codexbar-ios/rules/20103668))
is the repository's only ruleset. It targets `~DEFAULT_BRANCH`, is active, and
has no bypass actors. Classic branch protection returns 404, so the ruleset
supplies every main-branch requirement.

| Rule | Key parameters | Effect |
| --- | --- | --- |
| `non_fast_forward` | none | Blocks force pushes and rewrites of `main`. |
| `pull_request` | `required_review_thread_resolution: true`, `required_approving_review_count: 0`, `dismiss_stale_reviews_on_push: false`, `require_code_owner_review: false`, `require_last_push_approval: false` | Updates to `main` must arrive through a pull request, and every review conversation must be resolved before merge. |
| `required_status_checks` | `SwiftLint`, `Strict concurrency`, `iOS tests`, `watchOS tests`, `SwiftPM smoke tests`; `strict_required_status_checks_policy: true`; `do_not_enforce_on_create: true` | Preserved unchanged from the September 6, 2026 change recorded in [CI-POLICY.md](CI-POLICY.md). |

The exact payload for the ruleset is
[docs/branch-rulesets/main-20103668.json](docs/branch-rulesets/main-20103668.json).
Settings follow GitHub's
[available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets).

## Review-count policy

This repository requires zero approving reviews. It has a single owner and no
`CODEOWNERS` file, so a code-owner requirement would be empty and an approval
count of one would turn every merge into a manual owner step. The three
automated reviewers in [AGENTS.md](AGENTS.md) still review every pull request,
their actionable threads must be resolved, and the resolution requirement above
makes that a server-enforced condition. Correctness is gated by the five
required status checks, and the owner decides when the review loop is clean
enough to merge. Approvals are advisory signals, not a merge gate. Raising the
review count later follows the same change process as any other ruleset edit.

## Who can change the rules

Users with the "edit repository rules" permission, which means repository
administrators. For this repository that is the owner account, `HemSoft`. A
ruleset change follows the same issue-first workflow as any other repository
change: it starts with an issue, is documented through an issue-linked pull
request carrying the exact payload, is applied by an administrator with the REST
API, and is re-verified live afterwards.

## Apply and verify

```sh
gh api -X PUT repos/HemSoft/codexbar-ios/rulesets/20103668 \
  --input docs/branch-rulesets/main-20103668.json
gh api repos/HemSoft/codexbar-ios/rules/branches/main
gh api repos/HemSoft/codexbar-ios/rulesets/20103668
```

Confirm all three rules in the response: `non_fast_forward`, `pull_request` with
`required_review_thread_resolution: true`, and the unchanged
`required_status_checks`, with `bypass_actors` empty. After applying, record the
final ruleset JSON and the timestamp on the linked issue. Demonstrate
enforcement with a disposable test branch or ruleset, never with destructive
pushes against `main`: direct updates to the protected ref and merges with
unresolved conversations must be rejected.

## Change history

- September 6, 2026 at 5:13 p.m. EDT: ruleset 20103668 came to require the five
  correctness checks with strict freshness and no bypass actors. See
  [CI-POLICY.md](CI-POLICY.md).
- [Issue #305](https://github.com/HemSoft/codexbar-ios/issues/305): live
  inspection found no `pull_request` or `non_fast_forward` rule, so direct
  pushes and rewrites of `main` were possible. The payload in
  [docs/branch-rulesets/main-20103668.json](docs/branch-rulesets/main-20103668.json)
  adds both rules to the same ruleset. Application follows the human review this
  issue requires; the issue records the applied JSON and timestamp.
