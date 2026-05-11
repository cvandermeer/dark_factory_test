# Auto-Merge on Approval — Design

**Status:** Approved design, pending implementation plan
**Date:** 2026-04-29
**Repo:** https://github.com/cvandermeer/dark_factory_test
**Builds on:** `docs/superpowers/specs/2026-04-25-review-feedback-loop-design.md`

## Summary

Close the loop on the review flow: when the reviewer agent finds no real issues, the PR is auto-merged (squash) and the card moves to a terminal "Done" lane. After merge, the local `main` is fast-forwarded so the next feature request branches from the post-merge tip.

## Background — the bug this fixes

The review feedback loop currently transitions a card to `review_feedback` only when at least one PR review has `state == "CHANGES_REQUESTED"` (`PollPrReviewsJob`). This was working for human reviewers but breaks for the AI reviewer running on self-PRs:

- GitHub blocks PR authors from formally approving (`gh pr review --approve`) **and** requesting changes (`gh pr review --request-changes`) on their own PRs.
- Commit `88eabc9` worked around the approve restriction by switching the no-issues path to `gh pr review --comment`, but `--request-changes` is still in the prompt for the issues path. On a self-PR it would fail the same way.
- Net effect: every reviewer post on a self-PR ends up as `state: "COMMENTED"` regardless of verdict, so polling never transitions and the card sits in `to_review` indefinitely.

The fix replaces the `state`-based detection with a body-marker convention that works for both verdicts and on self-PRs.

## Goals

- Reviewer's verdict (approved vs changes requested) is detectable on self-PRs.
- Approved cards auto-merge and move to a terminal `done` lane.
- After auto-merge, local `main` is updated so subsequent feature requests branch from the latest tip.
- Failures during merge are captured in the existing `failed` lane with a typed reason.

## Non-goals

- Auto-merging on human reviewer approval (out of scope; humans still merge their own approvals via the GitHub UI). The new flow only fires when the AI reviewer marks the PR `[APPROVED]`.
- Multi-reviewer consensus (one AI reviewer post is the verdict).
- Recovering "stuck" cards where the reviewer omitted a marker — those stay in `to_review` and the user retries manually.
- Configurable merge strategy (squash is hardcoded for v1).
- Waiting for required CI checks before merging (`gh pr merge --auto`). v1 merges immediately; if branch protection blocks it, the card lands in `failed`.

## Column lifecycle

Seven columns now: **Todo / Doing / To review / Reviewing / Review feedback / Ready for release / Done / Failed.** (Failed remains the always-last column.)

```
todo → doing → to_review → reviewing → to_review
                                          ↓ poll detects marker
                          ┌───────────────┴───────────────┐
                          ↓ [APPROVED]                    ↓ [CHANGES REQUESTED]
                ready_for_release                  review_feedback
                          ↓ AutoMergeJob                  ↓ AddressFeedbackJob
                        done                            doing → to_review
                                                        (existing flow)
```

If the reviewer's body has no marker, the card stays in `to_review` (defensive default — reviewer is expected to comply).

## Data model changes

Extend `STATUSES` to:

```ruby
STATUSES = %w[todo doing to_review reviewing review_feedback ready_for_release done failed].freeze
```

No new columns. `last_review_seen_at` remains the timestamp the polling job sets when it acts on a review. No schema migration required (status is a plain string).

## Components

### Reviewer prompt change — `script/run_agent.mjs`

The `reviewer` system prompt currently tells the agent to use `--request-changes` for issues and `--comment` for clean reviews. Replace with a single rule: **always `--comment`, prefix the body with one of two markers**.

New reviewer prompt (replacing lines 40–50 in `script/run_agent.mjs`):

> You are reviewing a pull request. Read the diff in the current directory using `git diff main...HEAD`. Compare the diff against the feature request title and body provided below. If there are real correctness, scope, or quality issues, run: `gh pr review <pr_url> --comment --body "[CHANGES REQUESTED] <your concerns, in plain English>"`. If there are no real issues, run: `gh pr review <pr_url> --comment --body "[APPROVED] <short positive note>"`. The marker MUST be the first token of the body — no other text before it. Do NOT use --approve or --request-changes — GitHub blocks both on self-PRs. Do NOT make any code changes. Do NOT commit. Do NOT push. Run exactly one `gh pr review` command and stop.

### `PollPrReviewsJob` — marker parsing

Replace the `state == "CHANGES_REQUESTED"` check with body-marker parsing of the most recent review:

```ruby
def check(fr)
  out, _err, status = Open3.capture3(
    { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
    "gh", "pr", "view", fr.pr_url, "--json", "reviews"
  )
  return unless status.success?

  reviews = JSON.parse(out).fetch("reviews", [])
  return if reviews.empty?

  body = reviews.last["body"].to_s.strip
  case body
  when /\A\[CHANGES REQUESTED\]/i
    fr.update!(status: "review_feedback", last_review_seen_at: Time.current)
  when /\A\[APPROVED\]/i
    fr.update!(status: "ready_for_release", last_review_seen_at: Time.current)
  end
end
```

Notes:
- Reads the **last** review (the AI reviewer posts exactly one). If a human later posts another review, the case/regex still picks up the latest verdict — but `feedback_addressed` already gates re-entry into `review_feedback`. The `ready_for_release` path has no analogous gate; once a card moves there, the polling job no longer matches it (the `where(status: "to_review", ...)` scope filters it out), so re-detection is moot.
- The polling-scope filter (`status: "to_review", feedback_addressed: false`) is unchanged.

### `FeatureRequest` callback

Add a sibling to the existing `enqueue_address_feedback_job` hook:

```ruby
after_update_commit :enqueue_auto_merge_job,
                    if: -> { saved_change_to_status? && status == "ready_for_release" }

def enqueue_auto_merge_job
  AutoMergeJob.perform_later(id)
end
```

### `AutoMergeJob` (new)

```ruby
class AutoMergeJob < ApplicationJob
  queue_as :default

  REPO_ROOT = Rails.root.to_s # the dark_factory app's main checkout — see Open question 1

  def perform(fr_id)
    fr = FeatureRequest.find(fr_id)
    return unless fr.status == "ready_for_release"

    merge!(fr)
    sync_main!
    fr.update!(status: "done")
  rescue => e
    fr&.update!(status: "failed", failure_reason: "auto_merge_failed: #{e.message}")
  end

  private

  def merge!(fr)
    out, err, status = Open3.capture3(
      { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
      "gh", "pr", "merge", fr.pr_url, "--squash", "--delete-branch"
    )
    raise "gh pr merge failed: #{err.presence || out}" unless status.success?
  end

  def sync_main!
    run!("git", "-C", REPO_ROOT, "fetch", "origin", "main")
    run!("git", "-C", REPO_ROOT, "checkout", "main")
    run!("git", "-C", REPO_ROOT, "pull", "--ff-only", "origin", "main")
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "#{cmd.first} failed: #{err.presence || out}" unless status.success?
  end
end
```

The job runs synchronously in the worker; no streaming of agent events (there's no agent — just shell commands).

### Failure handling

All failures land in the existing `Failed` column with a typed `failure_reason`:

| Failure | `failure_reason` |
|---|---|
| `gh pr merge` rejected (branch protection, conflicts, CI red, already-merged race) | `auto_merge_failed: gh pr merge failed: <stderr>` |
| `git fetch` / `git checkout main` / `git pull --ff-only` failed | `auto_merge_failed: git <cmd> failed: <stderr>` |
| Anything else | `auto_merge_failed: <error message>` |

The PR may have already been merged when the job runs (e.g., user merged manually between approval and the job firing). `gh pr merge` returns an error in that case; we treat it as a failure for v1 and let the user manually mark the card done. (Improvement candidate for v2: detect "already merged" and transition to `done` anyway.)

### UI changes

- Add **"Ready for release"** column between "Reviewing" and "Failed", and **"Done"** column between "Ready for release" and "Failed".
- Card styling for `ready_for_release`: green left-border (`border-left: 3px solid #22c55e`) with a "merging…" spinner — mirrors the existing `reviewing` pattern.
- Card styling for `done`: muted/grey left-border, possibly a checkmark — visually de-emphasized since the work is finished.
- Card detail page: existing event stream is unchanged; the merge has no agent events to render.

## Open implementation questions

Deliberately deferred to the implementation plan:

1. **Repo root for `git pull --ff-only`** — the AutoMergeJob runs `git -C <REPO_ROOT> ...` to update local `main`. Is `Rails.root` the right path? Or is the dark_factory app and the target repo (`dark_factory_test`) different checkouts? Confirm in the plan by reading where `WorktreeManager` derives `repo_root` and reuse the same constant.
2. **What if there are uncommitted changes on local `main`** when the job runs? `git checkout main` will fail. Worth a one-line `git status --porcelain` check up front with a clearer error, or accept the cryptic git stderr.
3. **Card visibility during merge** — `ready_for_release` is transient. On a fast merge it may flicker through the column. Acceptable for v1; if it's annoying, add a deliberate min-display delay later.
4. **Marker case sensitivity** — the regex uses `/i`. Reviewer prompt says uppercase. Consider whether to be strict (uppercase only) or lenient. Lenient is safer.

## Out of scope (for a hypothetical v3)

- Auto-merge on human approval.
- Configurable merge strategy (squash / merge / rebase).
- Wait-for-CI semantics (`gh pr merge --auto`).
- Retry queue for `auto_merge_failed` cards.
- Detecting "PR already merged" and treating it as success.
- A separate "Merging…" status distinct from `ready_for_release` (merging happens fast enough that one transient state is fine).
