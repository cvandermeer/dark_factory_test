# Review Feedback Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AI reviewer agent that fires after each PR opens, a "Review feedback" Kanban column for cards with `CHANGES_REQUESTED` reviews, and an addressing agent that picks up those cards and pushes a follow-up commit to the same PR — all capped at one round per feature request.

**Architecture:** Three new jobs (`ReviewAgentJob` chained after `DarkFactoryJob`; `PollPrReviewsJob` recurring; `AddressFeedbackJob` triggered by status transition). Two existing services extended (`WorktreeManager` gains a `mode:` option; `AgentRunner` gains a `mode:` option). One Node script (`script/run_agent.mjs`) gains `--mode` to switch system prompts. One new service (`FeedbackFetcher`) wraps `gh api` calls. One DB migration adds two columns + a status enum value.

**Tech Stack:** Same as the original Dark Factory — Rails 8.1, SolidQueue, SolidCable, Turbo Streams, sqlite3, Node 20+, `@anthropic-ai/claude-agent-sdk`, `gh` CLI, `git worktree`.

**Design spec:** `docs/superpowers/specs/2026-04-25-review-feedback-loop-design.md`

**Testing note:** per user direction, no Rails-side test suite. Each task ends with a manual smoke test. Generated-code correctness on resulting PRs is validated by the target repo's CI.

**Prerequisites:**
- Original Dark Factory build is on `main` and runnable (`bin/rails s` + `bin/jobs` + `.env` with `ANTHROPIC_API_KEY`).
- `gh auth status` shows authenticated.
- A feature request can already round-trip end-to-end (verified by Tasks 12 + 15 of the original plan).

---

## Task 1: Migration + status enum + `feedback_addressed` column

**Files:**
- Create: `db/migrate/<timestamp>_add_review_feedback_to_feature_requests.rb`
- Modify: `app/models/feature_request.rb`

- [ ] **Step 1: Generate migration**

Run: `bin/rails g migration AddReviewFeedbackToFeatureRequests feedback_addressed:boolean last_review_seen_at:datetime`
Expected: migration file created.

- [ ] **Step 2: Edit the migration**

Replace the generated migration body with:

```ruby
class AddReviewFeedbackToFeatureRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :feature_requests, :feedback_addressed, :boolean, null: false, default: false
    add_column :feature_requests, :last_review_seen_at, :datetime
  end
end
```

- [ ] **Step 3: Update `STATUSES` and add the new scope on `FeatureRequest`**

Modify `app/models/feature_request.rb`:

```ruby
# Replace the STATUSES constant:
STATUSES = %w[todo doing to_review review_feedback failed].freeze

# Add a new scope alongside the existing scopes:
scope :review_feedback, -> { where(status: "review_feedback") }
```

- [ ] **Step 4: Run migration and smoke test**

Run:
```bash
bin/rails db:migrate
bin/rails runner '
  fr = FeatureRequest.create!(title: "Test", body: "x")
  puts "feedback_addressed default: #{fr.feedback_addressed}"
  fr.update!(status: "review_feedback")
  puts "valid review_feedback status: #{fr.valid?}"
  puts "scope: #{FeatureRequest.review_feedback.count}"
  FeatureRequest.destroy_all
'
```
Expected output:
```
feedback_addressed default: false
valid review_feedback status: true
scope: 1
```

- [ ] **Step 5: Commit**

```bash
git add db/migrate/*add_review_feedback_to_feature_requests.rb db/schema.rb app/models/feature_request.rb
git commit -m "feat: add feedback_addressed flag and review_feedback status"
```

---

## Task 2: `WorktreeManager` — add `mode:` for checking out existing branches

**Files:**
- Modify: `app/services/worktree_manager.rb`

- [ ] **Step 1: Replace the class with the mode-aware version**

Replace `app/services/worktree_manager.rb`:

```ruby
class WorktreeManager
  class Error < StandardError; end

  MODES = [:create_branch, :checkout_existing].freeze

  attr_reader :path, :branch

  # mode: :create_branch (default) — `git worktree add -b <branch> <path> <base>` creates a new branch.
  # mode: :checkout_existing — `git worktree add <path> <branch>` checks out an existing branch.
  def initialize(repo_root:, branch:, base: "main", mode: :create_branch)
    raise ArgumentError, "unknown mode #{mode}" unless MODES.include?(mode)
    @repo_root = repo_root
    @branch = branch
    @base = base
    @mode = mode
    @path = File.expand_path("../df_work/fr-#{SecureRandom.hex(4)}", repo_root)
  end

  def setup!
    FileUtils.mkdir_p(File.dirname(@path))
    case @mode
    when :create_branch
      run!("git", "-C", @repo_root, "worktree", "add", "-b", @branch, @path, @base)
    when :checkout_existing
      run!("git", "-C", @repo_root, "fetch", "origin", @branch)
      run!("git", "-C", @repo_root, "worktree", "add", @path, "origin/#{@branch}")
    end
    @path
  end

  def teardown!
    return unless File.directory?(@path)
    run!("git", "-C", @repo_root, "worktree", "remove", "--force", @path)
  rescue Error => e
    Rails.logger.warn("[WorktreeManager] teardown failed, forcing fs cleanup: #{e.message}")
    FileUtils.rm_rf(@path)
  end

  private

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise Error, "#{cmd.join(' ')}: exit #{status.exitstatus}\n#{err}" unless status.success?
    out
  end
end
```

Note: `:checkout_existing` always fetches from origin first and then checks out `origin/<branch>` into a detached state. We use `origin/<branch>` rather than the local branch because the local branch may not exist (or may be out of date) in the main checkout. The reviewer/addressing agent will commit on top of the detached HEAD; before pushing, the calling code can rename HEAD back to the branch using `git switch -C <branch>` inside the worktree (handled by Task 6 / 9).

- [ ] **Step 2: Smoke test (create_branch mode still works)**

Run:
```bash
bin/rails runner '
  wm = WorktreeManager.new(repo_root: Rails.root.to_s, branch: "test-wm-#{Time.now.to_i}")
  wm.setup!
  puts "created exists: #{File.directory?(wm.path)}"
  wm.teardown!
'
git branch | grep test-wm- | xargs git branch -D 2>/dev/null; true
```
Expected: `created exists: true`.

- [ ] **Step 3: Smoke test (checkout_existing mode)**

To test `:checkout_existing`, you need an existing remote branch. Create one quickly:

```bash
git checkout -b smoke-existing main
echo "smoke" > /tmp/smoke.txt
git checkout main
git push origin smoke-existing
git branch -D smoke-existing
```

Then:
```bash
bin/rails runner '
  wm = WorktreeManager.new(repo_root: Rails.root.to_s, branch: "smoke-existing", mode: :checkout_existing)
  wm.setup!
  puts "exists: #{File.directory?(wm.path)}, gemfile: #{File.exist?(File.join(wm.path, "Gemfile"))}"
  wm.teardown!
'
```
Expected: `exists: true, gemfile: true`.

Clean up: `git push origin --delete smoke-existing`.

- [ ] **Step 4: Commit**

```bash
git add app/services/worktree_manager.rb
git commit -m "feat: WorktreeManager supports checkout_existing mode"
```

---

## Task 3: `script/run_agent.mjs` — add `--mode` flag

**Files:**
- Modify: `script/run_agent.mjs`

- [ ] **Step 1: Replace the script**

Replace `script/run_agent.mjs`:

```javascript
#!/usr/bin/env node
// Runs a Claude Agent SDK session inside a pre-existing worktree.
// Reads JSON from stdin (shape depends on --mode).
// Writes one JSON event per line to stdout.
// Exits 0 on success, nonzero on error.

import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import process from "node:process";

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function parseArgs(argv) {
  const args = { worktree: null, mode: "implement" };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--worktree") args.worktree = argv[++i];
    else if (argv[i] === "--mode") args.mode = argv[++i];
  }
  if (!args.worktree) {
    console.error("usage: run_agent.mjs --worktree <path> [--mode implement|reviewer|address]");
    process.exit(2);
  }
  if (!["implement", "reviewer", "address"].includes(args.mode)) {
    console.error(`unknown mode: ${args.mode}`);
    process.exit(2);
  }
  return args;
}

const SYSTEM_PROMPTS = {
  implement: [
    "You are a software engineer working in a Rails 8 app.",
    "Implement the feature described below in the current directory.",
    "When finished, commit your changes with a clear message using git.",
    "Do NOT push the branch and do NOT open a pull request — the caller handles that.",
  ].join(" "),

  reviewer: [
    "You are reviewing a pull request.",
    "Read the diff in the current directory using `git diff main...HEAD`.",
    "Compare the diff against the feature request title and body provided below.",
    "If there are real correctness, scope, or quality issues, run:",
    "`gh pr review <pr_url> --request-changes --body \"<your concerns, in plain English>\"`.",
    "If there are no real issues, run: `gh pr review <pr_url> --approve`.",
    "Do NOT make any code changes. Do NOT commit. Do NOT push.",
    "Run exactly one `gh pr review` command and stop.",
  ].join(" "),

  address: [
    "You are addressing review feedback on a pull request.",
    "The original feature request, the current diff, and the reviewer's comments are below.",
    "Make the code changes that the reviewer requested.",
    "Commit your changes with a clear message using git.",
    "Do NOT push and do NOT open a PR — the caller handles that.",
  ].join(" "),
};

const { worktree, mode } = parseArgs(process.argv);
const stdin = readFileSync(0, "utf-8");
const payload = JSON.parse(stdin);

function buildUserPrompt(mode, payload) {
  const { title, body, pr_url, diff, feedback } = payload;
  switch (mode) {
    case "implement":
      return `Feature request:\n\nTitle: ${title}\n\nBody:\n${body}`;
    case "reviewer":
      return [
        `PR URL: ${pr_url}`,
        `Original feature request:\nTitle: ${title}\nBody:\n${body}`,
        `Use \`git diff main...HEAD\` to read the diff.`,
        `Decide: --request-changes or --approve.`,
      ].join("\n\n");
    case "address":
      return [
        `Original feature request:\nTitle: ${title}\nBody:\n${body}`,
        `Current diff:\n${diff}`,
        `Reviewer feedback:\n${feedback}`,
        `Address the feedback and commit.`,
      ].join("\n\n");
  }
}

const userPrompt = buildUserPrompt(mode, payload);

process.chdir(worktree);

try {
  const iterator = query({
    prompt: userPrompt,
    options: {
      systemPrompt: SYSTEM_PROMPTS[mode],
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      cwd: worktree,
      // Hermetic — no user/project plugins or hooks.
      settingSources: [],
    },
  });

  for await (const message of iterator) {
    emit({ raw: message });
  }
  emit({ raw: { type: "done" } });
  process.exit(0);
} catch (err) {
  emit({ raw: { type: "error", error: { name: err.name, message: err.message, stack: err.stack } } });
  process.exit(1);
}
```

- [ ] **Step 2: Smoke test — script syntax + arg validation**

```bash
node --check script/run_agent.mjs && echo "syntax OK"
echo '{"title":"x","body":"y"}' | node script/run_agent.mjs 2>&1 | tail -2
echo '{}' | node script/run_agent.mjs --worktree /tmp --mode bogus 2>&1 | tail -2
```
Expected:
```
syntax OK
usage: run_agent.mjs --worktree <path> [--mode implement|reviewer|address]
unknown mode: bogus
```

- [ ] **Step 3: Smoke test — implement mode still works (regression check)**

Use the existing happy-path E2E from the original Task 12 of the prior plan (submit a tiny FR, watch it complete). Skip if Anthropic credits are tight — Task 13 below has a more comprehensive end-to-end test that catches this regression.

- [ ] **Step 4: Commit**

```bash
git add script/run_agent.mjs
git commit -m "feat: Node agent script supports reviewer and address modes"
```

---

## Task 4: `AgentRunner` — accept `mode:` option, pass `--mode`

**Files:**
- Modify: `app/services/agent_runner.rb`

- [ ] **Step 1: Replace the class**

Replace `app/services/agent_runner.rb`:

```ruby
class AgentRunner
  class AgentFailed < StandardError; end
  class Timeout < StandardError; end

  DEFAULT_TIMEOUT = 15 * 60 # seconds

  # mode: :implement (default), :reviewer, or :address
  # stdin_payload: the hash that gets JSON-encoded and piped to the Node subprocess.
  #   - implement: { title:, body: }
  #   - reviewer:  { title:, body:, pr_url: }
  #   - address:   { title:, body:, diff:, feedback: }
  def initialize(feature_request:, worktree_path:, mode: :implement, stdin_payload: nil, timeout: DEFAULT_TIMEOUT)
    @fr = feature_request
    @worktree = worktree_path
    @mode = mode
    @stdin_payload = stdin_payload || { title: @fr.title, body: @fr.body }
    @timeout = timeout
    @sequence = @fr.agent_events.maximum(:sequence).to_i + 1
  end

  def run!
    cmd = ["node", Rails.root.join("script/run_agent.mjs").to_s,
           "--worktree", @worktree, "--mode", @mode.to_s]
    env = { "ANTHROPIC_API_KEY" => ENV["ANTHROPIC_API_KEY"] }

    Rails.logger.info("[AgentRunner mode=#{@mode}] spawning: #{cmd.join(' ')}")
    stderr_buf = +""
    exit_status = nil

    Open3.popen3(env, *cmd, chdir: Rails.root.to_s) do |stdin, stdout, stderr, wait_thr|
      stdin.write(JSON.dump(@stdin_payload))
      stdin.close

      err_reader = Thread.new { stderr.each_line { |l| stderr_buf << l } }

      started = Time.now
      stdout.each_line do |line|
        raise Timeout if Time.now - started > @timeout
        handle_line(line)
      end

      err_reader.join(2)
      exit_status = wait_thr.value.exitstatus
    end

    if exit_status != 0
      last_error = @fr.agent_events.where(kind: "error").order(:sequence).last&.payload&.dig("message")
      tail = stderr_buf.lines.last(40).join
      detail = last_error.presence || tail.presence || "(no output)"
      raise AgentFailed, "agent_exited: #{exit_status} — #{detail}"
    end
  end

  private

  def handle_line(line)
    raw = JSON.parse(line)
    kind, payload = classify(raw["raw"] || raw)
    event = @fr.agent_events.create!(kind: kind, payload: payload, sequence: @sequence)
    @sequence += 1
    broadcast(event)
  rescue JSON::ParserError
    Rails.logger.warn("[AgentRunner] non-JSON stdout: #{line.inspect}")
  end

  def classify(msg)
    case msg["type"]
    when "assistant", "text"
      ["text", { "content" => extract_text(msg) }]
    when "tool_use"
      ["tool_use", { "tool" => msg["name"], "args" => msg["input"] }]
    when "tool_result"
      ["tool_result", { "tool" => msg["name"], "output" => stringify_output(msg["content"]) }]
    when "error"
      ["error", { "message" => msg.dig("error", "message") || msg["message"].to_s }]
    when "done"
      ["system", { "message" => "agent finished (#{@mode})" }]
    else
      ["system", { "message" => msg.inspect.truncate(1000) }]
    end
  end

  def extract_text(msg)
    content = msg["content"] || msg["text"]
    return content if content.is_a?(String)
    return content.map { |c| c.is_a?(Hash) ? c["text"].to_s : c.to_s }.join if content.is_a?(Array)
    msg.inspect
  end

  def stringify_output(content)
    return content if content.is_a?(String)
    return content.map { |c| c.is_a?(Hash) ? c["text"].to_s : c.to_s }.join if content.is_a?(Array)
    content.inspect
  end

  def broadcast(event)
    Turbo::StreamsChannel.broadcast_append_to(
      "feature_request_#{@fr.id}_events",
      target: "fr-#{@fr.id}-events",
      partial: "agent_events/event",
      locals: { event: event }
    )
  end
end
```

Notes on the diff vs. the previous version:
- New `mode:` constructor option.
- New `stdin_payload:` constructor option (defaults to `{ title:, body: }` for backward compatibility with the implement flow).
- The Node command now includes `--mode <mode>`.
- The `done` event now mentions which mode finished, for the event log.

- [ ] **Step 2: Verify it loads cleanly**

Run: `bin/rails runner 'puts AgentRunner.new(feature_request: FeatureRequest.new(title: "x", body: "y"), worktree_path: "/tmp").class'`
Expected: `AgentRunner` (no exception).

- [ ] **Step 3: Commit**

```bash
git add app/services/agent_runner.rb
git commit -m "feat: AgentRunner supports mode and custom stdin payload"
```

---

## Task 5: `FeedbackFetcher` service

**Files:**
- Create: `app/services/feedback_fetcher.rb`

- [ ] **Step 1: Create the service**

Create `app/services/feedback_fetcher.rb`:

```ruby
class FeedbackFetcher
  class Error < StandardError; end

  def initialize(pr_url:)
    @pr_url = pr_url
  end

  # Returns a single string with all CHANGES_REQUESTED review bodies and inline comments,
  # formatted for inclusion in the addressing agent's prompt.
  def fetch_feedback
    reviews = gh_json("pr", "view", @pr_url, "--json", "reviews").fetch("reviews", [])
    comments = gh_json("api", "repos/#{slug}/pulls/#{number}/comments", "--paginate") rescue []

    sections = []

    reviews.select { |r| r["state"] == "CHANGES_REQUESTED" }.each do |r|
      author = r.dig("author", "login") || "unknown"
      body = r["body"].to_s.strip
      next if body.empty?
      sections << "Review by @#{author}:\n#{body}"
    end

    comments.each do |c|
      author = c.dig("user", "login") || "unknown"
      path = c["path"]
      line = c["line"] || c["original_line"]
      body = c["body"].to_s.strip
      next if body.empty?
      sections << "Inline comment by @#{author} on #{path}:#{line}:\n#{body}"
    end

    sections.join("\n\n---\n\n")
  end

  # Returns the current diff between the PR branch and main (the agent will reproduce this
  # with `git diff main...HEAD` inside the worktree, but we also pass it explicitly so the
  # prompt is self-contained).
  def fetch_diff(worktree_path)
    out, _err, status = Open3.capture3("git", "-C", worktree_path, "diff", "main...HEAD")
    raise Error, "could not compute diff" unless status.success?
    out
  end

  private

  def gh_json(*cmd)
    env = { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact
    out, err, status = Open3.capture3(env, "gh", *cmd)
    raise Error, "gh #{cmd.first(2).join(' ')}: #{err}" unless status.success?
    JSON.parse(out)
  end

  def slug
    # e.g. https://github.com/cvandermeer/dark_factory_test/pull/3 → cvandermeer/dark_factory_test
    @pr_url.sub(%r{^https?://github\.com/}, "").sub(%r{/pull/\d+/?$}, "")
  end

  def number
    # e.g. .../pull/3 → 3
    @pr_url[%r{/pull/(\d+)/?$}, 1]
  end
end
```

- [ ] **Step 2: Smoke test**

Pick any open PR you have access to (test repo, your own, etc.):

```bash
bin/rails runner '
  url = ARGV[0]
  fetcher = FeedbackFetcher.new(pr_url: url)
  puts "--- feedback ---"
  puts fetcher.fetch_feedback
' -- https://github.com/cvandermeer/dark_factory_test/pull/3
```

Expected: prints feedback (or empty string if no review comments). No exception.

If no PR with feedback exists, just verify it parses with an arbitrary PR URL — empty output is fine.

- [ ] **Step 3: Commit**

```bash
git add app/services/feedback_fetcher.rb
git commit -m "feat: add FeedbackFetcher service"
```

---

## Task 6: `ReviewAgentJob`

**Files:**
- Create: `app/jobs/review_agent_job.rb`

- [ ] **Step 1: Create the job**

Create `app/jobs/review_agent_job.rb`:

```ruby
class ReviewAgentJob < ApplicationJob
  class ReviewerSilent < StandardError; end

  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)
    return unless fr.pr_url.present?

    worktree = WorktreeManager.new(
      repo_root: Rails.root.to_s,
      branch: fr.branch_name,
      mode: :checkout_existing
    )
    worktree.setup!

    begin
      AgentRunner.new(
        feature_request: fr,
        worktree_path: worktree.path,
        mode: :reviewer,
        stdin_payload: { title: fr.title, body: fr.body, pr_url: fr.pr_url }
      ).run!

      ensure_review_was_posted!(fr)
    rescue AgentRunner::Timeout
      fr.update!(status: "failed", failure_reason: "reviewer_timeout: 15 min")
    rescue AgentRunner::AgentFailed => e
      fr.update!(status: "failed", failure_reason: "reviewer_failed: #{e.message}")
    rescue ReviewerSilent => e
      fr.update!(status: "failed", failure_reason: e.message)
    ensure
      worktree.teardown!
    end
  rescue => e
    fr&.update!(status: "failed", failure_reason: "reviewer_crashed: #{e.class}: #{e.message}")
    raise
  end

  private

  def ensure_review_was_posted!(fr)
    out, _err, status = Open3.capture3(
      { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
      "gh", "pr", "view", fr.pr_url, "--json", "reviews"
    )
    return unless status.success?
    reviews = JSON.parse(out).fetch("reviews", [])
    if reviews.empty?
      raise ReviewerSilent, "reviewer_silent: agent completed without posting a review"
    end
  end
end
```

- [ ] **Step 2: Verify it loads**

Run: `bin/rails runner 'puts ReviewAgentJob.name'`
Expected: `ReviewAgentJob`.

- [ ] **Step 3: Commit**

```bash
git add app/jobs/review_agent_job.rb
git commit -m "feat: add ReviewAgentJob for AI PR review"
```

---

## Task 7: Chain `ReviewAgentJob` from `DarkFactoryJob`

**Files:**
- Modify: `app/jobs/dark_factory_job.rb`

- [ ] **Step 1: Enqueue ReviewAgentJob after PR creation**

Modify `app/jobs/dark_factory_job.rb` — change the success line inside the `begin` block:

Replace:
```ruby
      pr_url = PrCreator.new(feature_request: fr, worktree_path: worktree.path).create!
      fr.update!(status: "to_review", pr_url: pr_url)
```

With:
```ruby
      pr_url = PrCreator.new(feature_request: fr, worktree_path: worktree.path).create!
      fr.update!(status: "to_review", pr_url: pr_url)
      ReviewAgentJob.perform_later(fr.id)
```

- [ ] **Step 2: Smoke test (without Anthropic credit burn)**

Verify the chain enqueues correctly. Stub the reviewer:

```bash
bin/rails runner '
  # Spy on enqueues
  enqueued = []
  ActiveSupport::Notifications.subscribe("enqueue.active_job") do |*args|
    job = ActiveSupport::Notifications::Event.new(*args).payload[:job]
    enqueued << job.class.name
  end

  fr = FeatureRequest.create!(title: "Chain test", body: "x")
  fr.update!(status: "to_review", pr_url: "https://github.com/x/y/pull/1")
  # The actual chaining happens inside DarkFactoryJob.perform — we cant fully invoke that
  # here without the agent. Just verify ReviewAgentJob can be enqueued for an FR:
  ReviewAgentJob.perform_later(fr.id)
  puts "Enqueued: #{enqueued.inspect}"
  FeatureRequest.destroy_all
'
```
Expected: `Enqueued: ["ReviewAgentJob"]`.

- [ ] **Step 3: Commit**

```bash
git add app/jobs/dark_factory_job.rb
git commit -m "feat: chain ReviewAgentJob after successful PR creation"
```

---

## Task 8: `PollPrReviewsJob` + recurring config

**Files:**
- Create: `app/jobs/poll_pr_reviews_job.rb`
- Modify: `config/recurring.yml`

- [ ] **Step 1: Create the job**

Create `app/jobs/poll_pr_reviews_job.rb`:

```ruby
class PollPrReviewsJob < ApplicationJob
  queue_as :default

  def perform
    FeatureRequest.where(status: "to_review", feedback_addressed: false)
                  .where.not(pr_url: nil)
                  .find_each do |fr|
      check(fr)
    end
  end

  private

  def check(fr)
    out, _err, status = Open3.capture3(
      { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
      "gh", "pr", "view", fr.pr_url, "--json", "reviews"
    )
    return unless status.success?

    reviews = JSON.parse(out).fetch("reviews", [])
    if reviews.any? { |r| r["state"] == "CHANGES_REQUESTED" }
      fr.update!(status: "review_feedback", last_review_seen_at: Time.current)
    end
  rescue => e
    Rails.logger.warn("[PollPrReviewsJob] skipping FR##{fr.id}: #{e.class}: #{e.message}")
  end
end
```

- [ ] **Step 2: Register the recurring task**

Modify `config/recurring.yml` — under the `default: &default` anchor, add:

```yaml
default: &default
  poll_merged_prs:
    class: PollMergedPrsJob
    queue: default
    schedule: every 2 minutes
  poll_pr_reviews:
    class: PollPrReviewsJob
    queue: default
    schedule: every 2 minutes
```

(Leave the `development:` and `production:` sections that inherit from `default` untouched.)

- [ ] **Step 3: Smoke test**

Run: `bin/rails runner 'PollPrReviewsJob.perform_now; puts "ran"'`
Expected: `ran` (no exceptions; no FRs to act on yet, so no DB writes).

- [ ] **Step 4: Commit**

```bash
git add app/jobs/poll_pr_reviews_job.rb config/recurring.yml
git commit -m "feat: add PollPrReviewsJob recurring task"
```

---

## Task 9: `AddressFeedbackJob`

**Files:**
- Create: `app/jobs/address_feedback_job.rb`

- [ ] **Step 1: Create the job**

Create `app/jobs/address_feedback_job.rb`:

```ruby
class AddressFeedbackJob < ApplicationJob
  class NoChangesMade < StandardError; end

  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)
    return unless fr.status == "review_feedback"

    fr.update!(status: "doing")

    worktree = WorktreeManager.new(
      repo_root: Rails.root.to_s,
      branch: fr.branch_name,
      mode: :checkout_existing
    )
    worktree.setup!

    begin
      # Make sure the worktree HEAD is on a branch (not detached) so the agent's commits
      # land somewhere we can push.
      Open3.capture3("git", "-C", worktree.path, "switch", "-C", fr.branch_name)

      fetcher = FeedbackFetcher.new(pr_url: fr.pr_url)
      diff = fetcher.fetch_diff(worktree.path)
      feedback = fetcher.fetch_feedback

      AgentRunner.new(
        feature_request: fr,
        worktree_path: worktree.path,
        mode: :address,
        stdin_payload: { title: fr.title, body: fr.body, diff: diff, feedback: feedback }
      ).run!

      ensure_agent_made_commits!(worktree.path, fr.branch_name)
      push_branch!(worktree.path, fr.branch_name)
      fr.update!(status: "to_review", feedback_addressed: true)
    rescue AgentRunner::Timeout
      fr.update!(status: "failed", failure_reason: "address_timeout: 15 min")
    rescue AgentRunner::AgentFailed => e
      fr.update!(status: "failed", failure_reason: "address_failed: #{e.message}")
    rescue NoChangesMade => e
      fr.update!(status: "failed", failure_reason: e.message)
    rescue PushFailed => e
      fr.update!(status: "failed", failure_reason: "address_push_failed: #{e.message}")
    ensure
      worktree.teardown!
    end
  rescue => e
    fr&.update!(status: "failed", failure_reason: "address_crashed: #{e.class}: #{e.message}")
    raise
  end

  class PushFailed < StandardError; end

  private

  def ensure_agent_made_commits!(worktree_path, branch)
    out, _err, status = Open3.capture3("git", "-C", worktree_path, "rev-list", "--count", "origin/#{branch}..HEAD")
    count = status.success? ? out.strip.to_i : 0
    if count.zero?
      raise NoChangesMade, "address_no_changes: agent finished without committing anything"
    end
  end

  def push_branch!(worktree_path, branch)
    _out, err, status = Open3.capture3(
      "git", "-C", worktree_path, "push", "origin", "HEAD:#{branch}"
    )
    raise PushFailed, err.to_s unless status.success?
  end
end
```

- [ ] **Step 2: Verify it loads**

Run: `bin/rails runner 'puts AddressFeedbackJob.name'`
Expected: `AddressFeedbackJob`.

- [ ] **Step 3: Commit**

```bash
git add app/jobs/address_feedback_job.rb
git commit -m "feat: add AddressFeedbackJob for follow-up commits"
```

---

## Task 10: Model callback to enqueue `AddressFeedbackJob`

**Files:**
- Modify: `app/models/feature_request.rb`

- [ ] **Step 1: Add the callback**

Modify `app/models/feature_request.rb` — add a new `after_update_commit` near the existing ones:

```ruby
  after_update_commit :enqueue_address_feedback_job, if: -> { saved_change_to_status? && status == "review_feedback" }
```

And add the corresponding private method (alongside `enqueue_dark_factory_job`):

```ruby
  def enqueue_address_feedback_job
    AddressFeedbackJob.perform_later(id)
  end
```

- [ ] **Step 2: Smoke test the callback fires**

```bash
bin/rails runner '
  enqueued = []
  ActiveSupport::Notifications.subscribe("enqueue.active_job") do |*args|
    job = ActiveSupport::Notifications::Event.new(*args).payload[:job]
    enqueued << job.class.name
  end

  fr = FeatureRequest.create!(title: "Callback test", body: "x", pr_url: "https://github.com/x/y/pull/1", branch_name: "feature-request/x")
  fr.update!(status: "to_review")
  enqueued.clear
  fr.update!(status: "review_feedback")
  puts "Enqueued on transition: #{enqueued.inspect}"
  FeatureRequest.destroy_all
'
```
Expected: `Enqueued on transition: ["AddressFeedbackJob"]`.

- [ ] **Step 3: Commit**

```bash
git add app/models/feature_request.rb
git commit -m "feat: enqueue AddressFeedbackJob on review_feedback transition"
```

---

## Task 11: UI — add "Review feedback" column + CSS

**Files:**
- Modify: `app/views/feature_requests/index.html.erb`
- Modify: `app/views/feature_requests/_card.html.erb`
- Modify: `app/assets/stylesheets/application.css`

- [ ] **Step 1: Add the new column to the index**

Modify `app/views/feature_requests/index.html.erb` — change the column iteration:

Replace:
```erb
  <% %w[todo doing to_review failed].each do |col| %>
```

With:
```erb
  <% %w[todo doing to_review review_feedback failed].each do |col| %>
```

The `humanize` call already pretty-prints `review_feedback` as `"Review feedback"`, so no other change to the column header.

- [ ] **Step 2: Update the grid to 5 columns**

Modify `app/assets/stylesheets/application.css` — change `.fr-board`:

Replace:
```css
.fr-board {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 16px;
  max-width: 1400px;
  margin: 0 auto;
}
```

With:
```css
.fr-board {
  display: grid;
  grid-template-columns: repeat(5, 1fr);
  gap: 16px;
  max-width: 1600px;
  margin: 0 auto;
}
```

- [ ] **Step 3: Add card variant for review_feedback + addressed indicator**

Modify `app/assets/stylesheets/application.css` — add to the card-variant section:

After the existing `.fr-card--failed` rule, add:

```css
.fr-card--review_feedback { border-left: 3px solid #a855f7; }

.fr-feedback-addressed {
  display: inline-block;
  margin-left: 6px;
  font-size: 11px;
  color: #a855f7;
}
```

- [ ] **Step 4: Show "feedback addressed" hint on cards in to_review after the round was used**

Modify `app/views/feature_requests/_card.html.erb` — find the `when "to_review"` block and add the hint:

Replace:
```erb
    <% when "to_review" %>
      <div class="fr-card__status">
        <% if feature_request.pr_url.present? %>
          <a href="<%= feature_request.pr_url %>" target="_blank" rel="noopener">PR ↗</a>
        <% end %>
        <% if feature_request.pr_merged_at.present? %>
          <span class="fr-merged">✓ merged</span>
        <% end %>
      </div>
```

With:
```erb
    <% when "to_review" %>
      <div class="fr-card__status">
        <% if feature_request.pr_url.present? %>
          <a href="<%= feature_request.pr_url %>" target="_blank" rel="noopener">PR ↗</a>
        <% end %>
        <% if feature_request.pr_merged_at.present? %>
          <span class="fr-merged">✓ merged</span>
        <% end %>
        <% if feature_request.feedback_addressed %>
          <span class="fr-feedback-addressed">↻ feedback addressed</span>
        <% end %>
      </div>
    <% when "review_feedback" %>
      <div class="fr-card__status">
        <% if feature_request.pr_url.present? %>
          <a href="<%= feature_request.pr_url %>" target="_blank" rel="noopener">PR ↗</a>
        <% end %>
        <span>review feedback received</span>
      </div>
```

- [ ] **Step 5: Smoke test**

Run: `bin/rails s -p 3000 -d` then visit http://localhost:3000/.

Expected: 5 columns visible, including the new "Review feedback" column between "To review" and "Failed".

Then create test cards in different states:
```bash
bin/rails runner '
  FeatureRequest.create!(title: "rf demo", body: "x", status: "review_feedback", branch_name: "x", pr_url: "https://example.com/pr/1")
  FeatureRequest.create!(title: "addressed demo", body: "x", status: "to_review", branch_name: "x", pr_url: "https://example.com/pr/2", feedback_addressed: true)
'
```

Reload the page. Expected:
- One card in "Review feedback" with purple left-border.
- One card in "To review" showing "↻ feedback addressed".

Clean up: `bin/rails runner 'FeatureRequest.destroy_all'` and `pkill -f 'puma.*3000'`.

- [ ] **Step 6: Commit**

```bash
git add app/views/feature_requests/index.html.erb app/views/feature_requests/_card.html.erb app/assets/stylesheets/application.css
git commit -m "feat: add Review feedback column and feedback-addressed indicator"
```

---

## Task 12: Update model broadcasts to handle the new column

**Files:**
- Modify: `app/models/feature_request.rb`

The existing `broadcast_card_refresh` already handles status transitions correctly via `broadcast_remove_to "board"` + `broadcast_prepend_to "board", target: "fr-column-#{status}"`. The DOM target `fr-column-review_feedback` matches the new column id from Task 11. **No code changes are needed here** — but you must verify the live broadcast works for the new column.

- [ ] **Step 1: Smoke test live broadcast**

Start `bin/rails s` + `bin/jobs` in two terminals. Open http://localhost:3000/ in a browser tab.

Run:
```bash
bin/rails runner '
  fr = FeatureRequest.create!(title: "Live broadcast test", body: "x")
  sleep 1
  fr.update!(status: "to_review", branch_name: "x", pr_url: "https://example.com/pr/1")
  sleep 1
  fr.update!(status: "review_feedback")
  sleep 5
  FeatureRequest.destroy_all
'
```

Expected (in the browser, no manual reload):
- Card appears in Todo, then jumps to To review, then jumps to Review feedback, then disappears.

If the card doesn't move to Review feedback live, the `broadcast_card_refresh` method needs the same template-target string for the new column — verify the DOM id format matches `fr-column-review_feedback` in the index view.

- [ ] **Step 2: Commit**

(Nothing to commit if no code changes were needed.)

If you discovered a bug and had to add explicit handling, commit:
```bash
git add app/models/feature_request.rb
git commit -m "fix: broadcast review_feedback column moves"
```

---

## Task 13: Final end-to-end demo smoke test

**Files:** none — this is a manual verification.

- [ ] **Step 1: Fresh state**

```bash
bin/rails runner 'FeatureRequest.destroy_all'
git branch | grep feature-request/ | xargs git branch -D 2>/dev/null; true
gh pr list --state open --search 'head:feature-request/' --json number --jq '.[].number' | xargs -I {} gh pr close {} --delete-branch 2>/dev/null; true
```

- [ ] **Step 2: Start everything**

Two terminals:
- Terminal A: `bin/rails s`
- Terminal B: `bin/jobs`

- [ ] **Step 3: Submit a tiny feature request**

Open http://localhost:3000/. Submit:
- Title: `Add a CONTRIBUTING.md`
- Body: `Create a CONTRIBUTING.md at the repo root with three sections: "Setup", "Testing", "Style". Each section should have one short paragraph.`

- [ ] **Step 4: Watch the implementer agent**

Card should:
- Appear in Todo → move to Doing → events stream live → move to To review with PR link.

Click the card. Verify the event log shows the implementer's tool uses (Edit, Write, Bash for git commit).

- [ ] **Step 5: Watch the reviewer agent**

Within ~10 seconds of the PR opening, `ReviewAgentJob` should kick off. Watch:
- More events streaming on the card's detail page (the reviewer's tool uses, eventually a `gh pr review --request-changes` or `--approve` Bash call).
- The card stays in "To review" while this runs.

Verify on GitHub: the PR has a review by your account (the AI reviewer). State should be either `APPROVED` or `CHANGES_REQUESTED`.

- [ ] **Step 6: Watch polling + addressing run**

If the reviewer left `CHANGES_REQUESTED`:
- Within 2 minutes, `PollPrReviewsJob` runs and the card moves from To review to Review feedback. Then the `after_update_commit` callback fires, enqueueing `AddressFeedbackJob`.
- The card moves from Review feedback back to Doing.
- New events stream as the addressing agent reads the diff + feedback and makes follow-up changes.
- Eventually the card moves back to To review with a "↻ feedback addressed" indicator.
- On GitHub, the PR has a new commit (the addressing agent's fix-up) on top of the original.

If the reviewer said `APPROVED`:
- The card stays in To review, no further activity. Submit a request you know will get `CHANGES_REQUESTED` (e.g., one with an obvious flaw the reviewer should catch — like asking for a feature that conflicts with the spec) to exercise the addressing path.

- [ ] **Step 7: Verify the one-round cap**

After the addressing run completes, manually open the PR on GitHub and post **another** `CHANGES_REQUESTED` review yourself.

Within 2 minutes (next poll cycle):
- The card should **not** move to Review feedback. It stays in To review.
- This is the lock at work — `feedback_addressed: true` excludes the FR from `PollPrReviewsJob`'s scope.

Verify: `bin/rails runner 'puts FeatureRequest.last.feedback_addressed'` should print `true`.

- [ ] **Step 8: Provoke a reviewer failure**

Test the `reviewer_silent` failure path: submit a request, but kill the reviewer subprocess mid-run (find it with `pgrep -f run_agent` and kill it). The job should mark the card as Failed with `reviewer_silent: ...` or `reviewer_failed: ...`.

This is hard to script reliably; if you can't reproduce it cleanly, skip — the path is wired in code and the smoke run in step 5 already exercises the happy paths.

- [ ] **Step 9: Clean up**

```bash
gh pr list --state open --search 'head:feature-request/' --json number --jq '.[].number' | xargs -I {} gh pr close {} --delete-branch 2>/dev/null; true
git branch | grep feature-request/ | xargs git branch -D 2>/dev/null; true
bin/rails runner 'FeatureRequest.destroy_all'
```

If everything in steps 4–7 worked, the feature is done.

---

## Appendix — Troubleshooting

- **Reviewer agent posts a review but card doesn't move.** Check `gh pr view <url> --json reviews` — if state is `COMMENTED` (not `CHANGES_REQUESTED`), the polling filter intentionally ignores it. Update the reviewer's prompt in `script/run_agent.mjs` to be more decisive, or extend the polling filter to include `COMMENTED` state too.

- **Address agent can't push.** Verify the worktree HEAD is on a branch (not detached) — the `git switch -C <branch>` line in `AddressFeedbackJob` handles this. If push still fails, the existing branch on origin may be ahead of local — fetch + rebase before pushing.

- **Card moves to Review feedback then immediately back to Doing then To review without visible events.** That's the addressing agent running and finishing very fast (e.g., agent says "no changes needed" and just commits an empty trail). Check the event log for the addressing run — the `address_no_changes` failure should have caught this. If it didn't, your agent likely committed something trivial; tighten the system prompt.

- **Polling never picks up the review.** Verify `bin/jobs` is running and SolidQueue's recurring tasks are firing. Run `PollPrReviewsJob.perform_now` manually to confirm the logic works.

- **`gh pr review` requires a non-empty body for `--request-changes`.** The reviewer's system prompt instructs it to include a body; if the agent forgets, the `gh` call will fail and bubble up as `reviewer_failed`. Tightening the prompt is the fix.
