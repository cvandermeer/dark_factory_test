# Review Feedback Loop — Design

**Status:** Approved design, pending implementation plan
**Date:** 2026-04-25
**Repo:** https://github.com/cvandermeer/dark_factory_test
**Builds on:** `docs/superpowers/specs/2026-04-24-dark-factory-design.md`

## Summary

Extend the Dark Factory with an AI reviewer agent that comments on each newly opened PR, plus a flow that picks up review feedback and runs a second coding pass to address it. Capped at one round per feature request to prevent infinite review/code loops.

## Goals

- After the factory opens a PR, an AI reviewer agent fires automatically, reads the diff against the original feature request, and submits either an `APPROVED` review or a `CHANGES_REQUESTED` review with comments.
- A polling job detects `CHANGES_REQUESTED` reviews (from AI or humans) on cards in `to_review` and moves them to a new "Review feedback" column.
- A coding agent picks the card up from "Review feedback", checks out the existing PR branch, addresses the comments, commits and pushes — extending the same PR.
- Hard cap at one feedback round per feature request.

## Non-goals

- Multi-round review/code loops.
- Auto-merging on `APPROVED` reviews (merging stays manual).
- Threaded inline reply to specific review comments. The reviewer posts a single top-level review; the addressing agent reads all comments and acts on them collectively.
- AI reviewer disagreement / dialogue with human reviewers — the reviewer always posts exactly once per PR and exits.
- A separate column for "addressing feedback" — the card reuses the existing `doing` column during the second run.

## Column lifecycle

Five columns now: **Todo / Doing / To review / Review feedback / Failed**.

```
todo → doing → to_review                              (original flow)
            ↑                  ↓ poll detects CHANGES_REQUESTED
            └── doing ←── review_feedback             (new — addressing run)
                            (one round only — feedback_addressed flips true)
```

If the reviewer submits `APPROVED`, the card stays in `to_review`. If a human later submits another `CHANGES_REQUESTED` review *after* `feedback_addressed: true`, the card still stays in `to_review` — the lock is engaged.

## Data model changes

Add two columns to `feature_requests`:

```
feedback_addressed:boolean   default: false, not null
last_review_seen_at:datetime nullable
```

- `feedback_addressed` — flips to `true` once the addressing agent finishes. The polling job ignores cards with `feedback_addressed: true`. This is the one-round cap.
- `last_review_seen_at` — set by the polling job when it acts on a review, used to ignore stale state across job restarts (and to provide a debug breadcrumb).

Extend `STATUSES` to `%w[todo doing to_review review_feedback failed]`.

`AgentEvent` schema is unchanged. Reviewer events and addressing-agent events both go into the same `agent_events` table for the same `feature_request_id`. Card detail page shows the full timeline of all three runs (initial, review, addressing) in `sequence` order.

## Components

### `ReviewAgentJob` (new)

Chained at the end of `DarkFactoryJob`'s success path:

```ruby
# in DarkFactoryJob, after fr.update!(status: "to_review", pr_url: pr_url)
ReviewAgentJob.perform_later(fr.id)
```

Job behavior:
1. Load FR; verify `pr_url` is set.
2. Worktree: check out the existing PR branch — `git worktree add ../df_work/review-fr-N <branch>` (no `-b`, no base — the branch already exists).
3. Spawn a Node subprocess with a reviewer system prompt:
   > You are reviewing a pull request. Read the diff. Compare it against the feature request title and body. If there are real correctness, scope, or quality issues, run `gh pr review <pr_url> --request-changes --body "<your concerns>"`. If there are no real issues, run `gh pr review <pr_url> --approve`. Do nothing else after that — no other commands.
4. Reuses `script/run_agent.mjs` with a new `--mode reviewer` flag. The mode switches the system prompt; the Node script otherwise behaves identically (NDJSON event stream, `settingSources: []` hermeticity, `permissionMode: "bypassPermissions"`).
5. Stream events into `agent_events` table (same flow as the implementer agent).
6. On any subprocess failure → set `status: "failed"`, `failure_reason: "reviewer_failed: <error>"`. **Note:** failures here move the card OUT of `to_review` into `failed`. That's a deliberate choice — a broken reviewer is treated as a real failure, not silently swallowed.
7. Worktree teardown in `ensure` block.

### `PollPrReviewsJob` (new) and extended polling

The existing `PollMergedPrsJob` keeps its responsibility (merge detection). A new sibling `PollPrReviewsJob` handles review feedback detection:

```ruby
# Recurring task — every 2 minutes (alongside PollMergedPrsJob)
class PollPrReviewsJob < ApplicationJob
  def perform
    FeatureRequest.where(status: "to_review", feedback_addressed: false)
                  .where.not(pr_url: nil)
                  .find_each { |fr| check(fr) }
  end

  private

  def check(fr)
    out, _err, status = Open3.capture3(
      { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
      "gh", "pr", "view", fr.pr_url, "--json", "reviews"
    )
    return unless status.success?
    reviews = JSON.parse(out)["reviews"] || []
    if reviews.any? { |r| r["state"] == "CHANGES_REQUESTED" }
      fr.update!(status: "review_feedback", last_review_seen_at: Time.current)
    end
  end
end
```

Both poll jobs registered in `config/recurring.yml`:

```yaml
default: &default
  poll_merged_prs:
    class: PollMergedPrsJob
    schedule: every 2 minutes
  poll_pr_reviews:
    class: PollPrReviewsJob
    schedule: every 2 minutes
```

### `AddressFeedbackJob` (new)

Triggered by an `after_update_commit` callback on `FeatureRequest` when status transitions into `review_feedback`:

```ruby
after_update_commit :enqueue_address_feedback_job, if: -> { saved_change_to_status? && status == "review_feedback" }

def enqueue_address_feedback_job
  AddressFeedbackJob.perform_later(id)
end
```

Job behavior:
1. Load FR. Set `status: "doing"` (card returns visually to the Doing column — Turbo broadcast handles the move).
2. Worktree: **check out** the existing PR branch — `git worktree add ../df_work/addr-fr-N <branch>` (no `-b`).
3. Fetch the PR's review comments and overall review bodies via `gh api repos/<owner>/<repo>/pulls/<num>/reviews` and `gh api repos/<owner>/<repo>/pulls/<num>/comments`. Concatenate into a single feedback string.
4. Build an enriched prompt for the agent:
    - Original FR title + body
    - The PR's current diff (`git -C <worktree> diff main...HEAD`)
    - The review feedback (concatenated)
   System prompt: "You are addressing review feedback on a pull request. The original feature request is below, along with the current diff and the reviewer's comments. Make the changes that the reviewer requested. Commit your changes with a clear message. Do NOT push and do NOT open a PR — the caller handles that."
5. Spawn `script/run_agent.mjs --mode address` (same script, different mode → different system prompt; user prompt body is the enriched payload).
6. Same `ensure_agent_made_commits!` guard. If the agent runs but commits nothing → `failure_reason: "address_no_changes: agent finished without committing anything"`, `status: "failed"`.
7. Push the branch (extends the existing PR — no new PR).
8. Set `status: "to_review"`, `feedback_addressed: true`. Lock engaged.
9. Worktree teardown in `ensure`.

### Modes in `script/run_agent.mjs`

The Node runner gains a `--mode` argument. Three modes share the same SDK call shape, differ only in system prompt:

| Mode | System prompt summary | Caller |
|---|---|---|
| `implement` (default) | "Implement the feature, commit, don't push or PR" | `DarkFactoryJob` (initial build) |
| `reviewer` | "Review the PR diff, run `gh pr review --request-changes` or `--approve`, do nothing else" | `ReviewAgentJob` |
| `address` | "Address the reviewer's feedback, commit, don't push or PR" | `AddressFeedbackJob` |

The `userPrompt` is constructed by the calling Rails service to fit the mode (FR text only for `implement`, FR + diff + comments for `address`, etc.). The Node runner stays simple: it just picks the right system prompt by mode.

### Service-layer additions

- `WorktreeManager` gains a `mode:` option: `:create_branch` (default, current behavior — `git worktree add -b ...`) or `:checkout_existing` (new — `git worktree add path branch-name`, no `-b`). Two modes, single class.
- `PrReviewer` service (new, parallel to `AgentRunner`) wraps the Node subprocess invocation for the `reviewer` mode. Or — simpler — extend `AgentRunner` with a `mode:` option. Recommendation: extend `AgentRunner`. The class is small enough that branching on mode keeps it cohesive without proliferating service files.
- `FeedbackFetcher` service (new) — wraps the `gh api` calls to pull review state + comments into a clean string for the addressing agent's prompt.

## Failure handling

All failures still land in the `Failed` column with a typed `failure_reason`. New entries:

| Mode | Detection | `failure_reason` |
|---|---|---|
| Reviewer subprocess errored | `AgentRunner::AgentFailed` raised in `ReviewAgentJob` | `reviewer_failed: <agent error>` |
| Reviewer ran but didn't post a review | `gh pr view --json reviews` after run still shows no review by us | `reviewer_silent: agent completed without posting a review` |
| Addressing subprocess errored | `AgentRunner::AgentFailed` raised in `AddressFeedbackJob` | `address_failed: <agent error>` |
| Addressing made no commits | `ensure_agent_made_commits!` raises `NoChangesMade` | `address_no_changes: agent finished without committing anything` |
| Addressing pushed but the PR is now in a bad state | `gh pr view` returns error | `address_push_failed: <error>` |

The `feedback_addressed` flag is **not** flipped to true on failure — so a human can manually retry by resubmitting (or by clearing the failed card and creating a new request). This is a deliberate design choice: failures don't consume the one round.

## UI changes

- New column: **"Review feedback"** between "To review" and "Failed".
- Card rendering: cards in `review_feedback` show a small "review feedback received" indicator.
- Card rendering for `to_review` after `feedback_addressed: true`: small "✓ feedback addressed" hint near the PR link, signalling that the round was used.
- Detail page event stream now includes events from up to three runs (initial implementer, reviewer, addressing). They're rendered in `sequence` order, no visual grouping needed for v1 — the existing event-by-kind rendering is fine.
- CSS: extend the existing color scheme. Suggest a purple left-border for `review_feedback` cards (`border-left: 3px solid #a855f7`), to match the existing pattern (`fr-card--doing` blue, `fr-card--to_review` green, `fr-card--failed` red).

## Out of scope (for a hypothetical v3)

- Configurable round limits (1, 2, 3 rounds — currently hardcoded to 1).
- Reviewer agent posting threaded inline comments instead of a single top-level review.
- A "request reviewer rerun" UI button if the reviewer's first pass was clearly wrong.
- Reviewer agent fetching prior review history when issuing a new review (e.g., for repeat-offender feedback patterns).
- Auto-merging on `APPROVED`.
- Different reviewer prompts per target repo / project type.

## Open implementation questions

Deliberately deferred to the implementation plan:

- Exact reviewer system prompt wording (the plan can iterate on this).
- Whether the reviewer should fetch and consider the project's `CONTRIBUTING.md` or `README.md` style guide as additional context. Probably yes; default to fetching `README.md` if present.
- Whether to also persist the reviewer's review body as a distinct `agent_events` row (kind `system` with subtype `review_posted`) for clean rendering on the detail page.
- Concurrency: with two new jobs (review + address) added to the chain, single-worker SolidQueue means total time for a request grows. For v1 we accept this. If it becomes a problem, jobs can be parallelized later.
