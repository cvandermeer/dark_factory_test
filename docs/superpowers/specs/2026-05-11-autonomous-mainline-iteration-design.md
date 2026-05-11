# Autonomous Mainline Iteration — Design

**Status:** Proposed replacement for the PR-first workflow
**Date:** 2026-05-11
**Repo:** https://github.com/cvandermeer/dark_factory_test
**Replaces:** PR creation, GitHub review polling, and auto-merge as the primary loop

## Summary

Dark Factory should optimize for autonomous iteration, not human-style pull-request ceremony. Each feature request still runs in an isolated worktree, but the system should automatically land successful agent work onto `main` after a local review and test pass. The review artifact is stored in the app, not expressed as a GitHub pull request.

This keeps the useful parts of the current design:

- isolated worktrees per agent run
- visible event streams
- durable git checkpoints
- AI reviewer pass
- feedback/addressing loop

It removes the GitHub PR as the coordination primitive.

## Why Change

The project history shows a steady expansion around pull requests:

- feature branches and PR creation
- AI reviewer job
- review feedback polling
- addressing feedback on the same PR branch
- proposed auto-merge once approved

That made sense when the PR was the human review boundary. For this experiment, the desired boundary is different: agents should keep iterating autonomously, and humans can inspect the resulting code afterward.

Using PRs creates avoidable friction:

- self-PR review limitations require marker conventions instead of normal approval states
- polling GitHub introduces latency and failure cases
- branch lifecycle and PR state become part of the core app behavior
- auto-merge recreates a local version of a queue that the app can own directly

## Recommended Workflow

Columns:

```text
Todo -> Implementing -> Reviewing -> Addressing feedback -> Landing -> Done
                                             \-> Failed
```

Behavior:

1. A feature request is created in `todo`.
2. `DarkFactoryJob` creates a disposable worktree and branch from current `main`.
3. The implementer agent edits, tests, and commits in the worktree.
4. A reviewer agent reviews the local diff, not a GitHub PR.
5. If the reviewer requests changes, the addressing agent updates the same branch and commits once.
6. The system runs the project verification command.
7. If verification passes, the branch is landed into local `main`.
8. The app records the landed commit SHA and moves the card to `done`.

No GitHub PR is required.

## Landing Strategy

Use a serialized local landing queue:

```text
git fetch origin main
git switch main
git pull --ff-only origin main
git merge --squash <agent-branch>
run verification
git commit -m "<feature title>"
git push origin main
```

The agent branch can be deleted after a successful push, or retained for debugging. Since rollback is not an important product requirement for this experiment, the primary durable artifact is the `main` commit plus the event log.

If `main` moved while the agent was working, rebase the agent branch onto current `main` before review or landing:

```text
git -C <worktree> fetch origin main
git -C <worktree> rebase origin/main
```

If rebase conflicts, move the card to `failed` with a typed reason. Do not invent complicated conflict recovery in v1.

## Local Review Artifact

Replace GitHub review state with an app-owned `agent_reviews` record or an `agent_events` entry.

Minimum viable shape:

```text
verdict: approved | changes_requested
body: text
diff_sha: string
created_at
```

The reviewer agent should output structured JSON to stdout:

```json
{
  "verdict": "changes_requested",
  "body": "The new route is missing a controller test."
}
```

The Rails job parses the verdict directly. There is no need to infer state from GitHub review APIs.

## Data Model Changes

Extend `feature_requests`:

```text
status             add: reviewing, addressing_feedback, landing, done
landed_commit_sha  string, nullable
review_verdict     string, nullable
review_body        text, nullable
```

The existing `pr_url` can remain nullable for older records, but new autonomous runs should not depend on it.

## Components To Replace

Remove or bypass:

- `PrCreator`
- `PollPrReviewsJob`
- `PollMergedPrsJob`
- GitHub PR review prompts in `script/run_agent.mjs`
- PR URL requirements in `ReviewAgentJob` and `AddressFeedbackJob`

Add:

- `LocalReviewerJob` or refactor `ReviewAgentJob` to local mode
- `LandingJob`
- `MainlineLandinger` service for serialized merge, verification, commit, and push
- structured reviewer output parsing

Keep:

- `WorktreeManager`
- `AgentRunner`
- `AgentEvent`
- feature request board and event stream
- one-round feedback cap for v1

## Human Review

Humans should review after landing by reading the commit diff from the app:

```text
git show <landed_commit_sha>
```

This matches the experiment: agents are allowed to change the product autonomously, and humans audit the result rather than gate every change.

For higher-risk moments, add a manual pause status later:

```text
Reviewing -> Awaiting human approval -> Landing
```

Do not make that the default.

## Failure Handling

Typed failure reasons:

| Failure | Reason |
|---|---|
| Implementer exits nonzero | `implement_failed: <details>` |
| Reviewer emits invalid JSON | `review_parse_failed: <details>` |
| Reviewer requests changes and address pass fails | `address_failed: <details>` |
| Verification fails | `verification_failed: <command output>` |
| Rebase conflict | `rebase_conflict: <details>` |
| Landing merge fails | `landing_failed: <details>` |
| Push to main fails | `push_main_failed: <details>` |

Failed branches should be kept by default for inspection.

## Recommendation

Do not build more around merge requests for this experiment. Keep git branches as temporary isolation, but make the app own review state and landing. The workflow should be:

```text
agent changes branch -> AI local review -> optional address pass -> tests -> squash onto main -> done
```

Then review the result in code through the landed commit and the event stream.
