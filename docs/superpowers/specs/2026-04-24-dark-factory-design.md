# Dark Factory — Design

**Status:** Approved design, pending implementation plan
**Date:** 2026-04-24
**Repo:** https://github.com/cvandermeer/dark_factory_test

## Summary

A self-referential Rails app that accepts feature requests from a Kanban-style UI, dispatches a headless Claude agent to implement each request in an isolated git worktree, and opens a pull request back to the same repo. Users watch the agent work in real time via streamed events on the request's detail view.

## Goals

- Submit a feature request and get a PR opened against `main` automatically, with no human approval step in between.
- Watch the agent's work stream live — tool uses, file edits, reasoning — on the request's detail page.
- Simple four-column Kanban board (Todo / Doing / To review / Failed) as the main UI.
- Runnable locally for a demo from `localhost`.

## Non-goals (v1)

- Authentication. Any visitor to `localhost` can submit.
- Rails-side automated tests of the factory plumbing. Correctness of generated code is enforced by the repo's existing CI, not by tests in this app.
- AI code review on opened PRs. Noted for v2.
- Webhook-based PR merge detection. Polling is used instead.
- A "Done" column. Merged PRs stay visually in "To review" with a ✓ merged indicator.
- Multi-worker / concurrent agents. Single worker, FIFO queue.
- Docker-based or remote sandboxing. Worktrees on the host are sufficient.

## High-level architecture

```
Browser                           Rails app                                  Worktree
───────                           ─────────                                  ────────
[/] Kanban page ──submit──▶ FeatureRequest (status: todo)
                                │
                                │ after_create: enqueue DarkFactoryJob
                                ▼
                            SolidQueue (single worker)
                                │
                                │ (1) git worktree add ../df_work/fr-<id> -b feature-request/<id>-<slug>
                                │ (2) spawn Node subprocess: script/run_agent.mjs
                                │     ├─ uses @anthropic-ai/claude-agent-sdk
                                │     ├─ permissionMode: "bypassPermissions"
                                │     └─ emits NDJSON events to stdout
                                │ (3) for each event: AgentEvent.create! + Turbo broadcast
                                │ (4) git push + gh pr create (--base main)
                                │ (5) FR.update! status: to_review, pr_url:
                                │     (or status: failed on exception/budget)
                                │ (6) git worktree remove
                                ▼
Browser card (Turbo Streams) ◀── live updates ──
```

## Data model

```
feature_requests
  id               bigint, PK
  title            string,    not null
  body             text,      not null
  status           enum [todo, doing, to_review, failed], default: todo, not null
  branch_name      string,    nullable  # populated when job starts
  pr_url           string,    nullable  # populated when PR opens
  pr_merged_at     datetime,  nullable  # populated by PollMergedPrsJob
  failure_reason   text,      nullable  # populated on failure only
  created_at, updated_at

agent_events
  id                  bigint, PK
  feature_request_id  bigint, FK, not null
  kind                string, not null  # "text" | "tool_use" | "tool_result" | "system" | "error"
  payload             jsonb,  not null  # raw event from the SDK
  sequence            integer, not null # monotonic per FR, used for ordering + replay
  created_at, updated_at
  index [feature_request_id, sequence] unique
```

Notes:
- `status` is the single source of truth for Kanban column placement.
- `agent_events` is append-only. Replay = rows ordered by `sequence`.
- `payload` is JSONB so we don't have to model every SDK event type up front.

## Job pipeline

```
DarkFactoryJob.perform(feature_request_id)
  1. load FR, update status: doing, Turbo-broadcast the card replace
  2. compute branch_name = "feature-request/#{id}-#{slug(title)}"
  3. git worktree add ../df_work/fr-#{id} -b <branch_name> main
  4. spawn subprocess:
        node script/run_agent.mjs \
          --worktree ../df_work/fr-#{id} \
          --feature-request-id <id>
     wrapped in a 15-minute timeout
  5. for each NDJSON line from stdout:
        parse → AgentEvent.create!(...)
        Turbo-broadcast append to stream "feature_request_<id>_events"
  6. on subprocess exit 0:
        cd worktree; git push -u origin <branch>
        gh pr create --base main --head <branch> \
          --title "<title>" --body "<body>\n\nRef: FR-<id>"
        parse PR URL from gh output
        FR.update! status: to_review, pr_url:
        Turbo-broadcast card replace (moves to "To review" column)
  7. on nonzero exit / timeout / exception:
        FR.update! status: failed, failure_reason: <see Failure handling>
        Turbo-broadcast card replace (moves to "Failed" column)
  8. ensure:
        git worktree remove --force ../df_work/fr-#{id}
        (local branch left in place for forensics)
```

### Supporting jobs

- **`PollMergedPrsJob`** — SolidQueue recurring task, every 2 minutes.
  For each `FeatureRequest` in `to_review` with `pr_url` present and `pr_merged_at` null:
  call `gh pr view <url> --json mergedAt,state`. If `mergedAt` is set, update `pr_merged_at`.
  Card stays in "To review" but renders a "✓ merged" indicator.

### Environment

Env vars the job needs:
- `ANTHROPIC_API_KEY` — passed through to the Node subprocess.
- `GH_TOKEN` — so `gh` works non-interactively.

Both are loaded from `.env` (not committed). A `.env.example` documents the required keys.

## Node agent script — `script/run_agent.mjs`

Thin wrapper around `@anthropic-ai/claude-agent-sdk`.

```
node script/run_agent.mjs --worktree <path> --feature-request-id <id>
```

Responsibilities:
- Reads feature request title + body from stdin (piped in by the Rails job).
- Sets `cwd` to the worktree path.
- Calls the SDK `query` function with `permissionMode: "bypassPermissions"` so the agent can Read/Edit/Write/Bash without prompts.
- System prompt: "You are a software engineer working in a Rails 8 app. Implement the feature described below. When done, commit your changes with a clear message. Do not push or open a PR — the caller handles that." (Wording finalized during implementation.)
- Streams the SDK's message stream to stdout as newline-delimited JSON, one object per event.
- Exits 0 on clean completion, nonzero on any error.
- Does **not** run `git push` or `gh pr create`. The Rails job does those, so push/PR failures are handled as Rails-side exceptions.

## Streaming plumbing

Hotwire Turbo Streams, over two channels:

- `"board"` — the Kanban page subscribes. Card status changes broadcast `broadcast_replace_to` so the card re-renders in place; CSS grid reflows it into the new column.
- `"feature_request_<id>_events"` — the detail modal subscribes. Each `AgentEvent.create!` triggers a `broadcast_append_to`.

SolidQueue runs in a separate process from Puma. Broadcasts go through Action Cable → SolidCable → browser. Scaffold has SolidCable configured out of the box; no extra setup.

### Event rendering

Single partial `app/views/agent_events/_event.html.erb` branches on `event.kind`:

- `text` — prose block (model narration / reasoning).
- `tool_use` — collapsible row: `🔧 <tool_name>(<args summary>)`.
- `tool_result` — collapsible row: first ~20 lines of result, truncated.
- `error` — red callout.
- `system` — muted.

Container is a scrollable div with max-height; newest events at the bottom; auto-scroll to bottom on append (unless the user has scrolled up).

### Modal reload behavior

Opening the detail modal loads existing `AgentEvent` rows from DB in `sequence` order, then subscribes to the live stream. Reloading mid-run shows the full history from DB, then continues tailing — no missed events.

## Failure handling

All failures land in the Failed column with a human-readable `failure_reason`.

| Mode | Detection | `failure_reason` format |
|---|---|---|
| Agent subprocess exits nonzero | `$?.exitstatus != 0` | `"agent_exited: <code>\n<last 40 lines of stderr>"` |
| Budget exceeded | `Timeout::Error` around the subprocess | `"budget_exceeded: 15 min"` |
| Git/gh failure after agent succeeded | Exception around `git push` / `gh pr create` | `"push_failed: <stderr>"` |
| Rails-side crash | top-level `rescue => e` in `perform` | `"job_crashed: <e.class>: <e.message>"` |

Cleanup: `ensure` block runs `git worktree remove --force`. Local branch kept regardless (forensic value). No automatic retry. Failed cards can be deleted manually.

Failed cards render the `failure_reason` truncated on the card and full-text in the modal.

## UI

Single board page at `/`:

- Four columns: **Todo**, **Doing**, **To review**, **Failed**.
- Submission form at the top (or a modal button): title + body textarea → POST creates an FR.
- Cards are compact: title, truncated body, status badge, small "running…" indicator when `doing`, PR link + merged state when `to_review`, failure reason preview when `failed`.
- Click a card → modal showing full body, full event log (replays + tails live), PR link.
- Delete button on cards in `failed` or `to_review` (doesn't touch GitHub; just removes the local record).

## Testing strategy

Per user direction:

- **No Rails-side test suite** for the factory plumbing in v1.
- The target repo's existing CI runs `bin/rails test` on every PR — that's the correctness gate for generated code.
- Manual smoke testing on a staging env after merge.

## v2 — deferred scope

Captured here so nothing is lost:

- **AI code reviewer** — a second agent that reviews the PR and posts review comments via `gh pr review --comment`. Triggered after the factory opens the PR.
- Webhook-based PR merge detection (replaces polling).
- Done column + card move on merge.
- Rails-side automated tests of the factory (stub the agent runner; test the job, models, board flow).
- Concurrent agents (pool of N workers).
- Authentication on the submission form.
- Moving from host-worktree execution to Docker containers for stronger isolation.

## Open implementation questions

These are deliberately left for the implementation plan, not the design:

- Exact system prompt text for the agent.
- CSS/styling approach for the board (Tailwind? Plain CSS? Pulse UI?).
- Exact shape of the `AgentEvent.payload` normalization (do we flatten SDK events or store them raw?).
- Recurring-task registration for `PollMergedPrsJob` (SolidQueue's recurring job DSL vs. a cron-like external trigger).
