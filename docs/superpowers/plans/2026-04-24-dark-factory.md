# Dark Factory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-referential Rails app with a Kanban board where users submit feature requests and a headless Claude agent implements each one in a git worktree and opens a PR against the same repo — with live-streamed agent events in the UI.

**Architecture:** Rails 8 + SolidQueue single-worker job. Node subprocess runs `@anthropic-ai/claude-agent-sdk` inside a throwaway git worktree, streams NDJSON events to stdout. Rails job parses each event into an `AgentEvent` row and broadcasts via Turbo Streams. On success, the job pushes the branch and opens a PR via `gh`. A recurring SolidQueue task polls GitHub for merged-at timestamps.

**Tech Stack:** Rails 8.1, SolidQueue, SolidCable, Turbo Streams, sqlite3, Node 20+, `@anthropic-ai/claude-agent-sdk`, `gh` CLI, `git worktree`.

**Design spec:** `docs/superpowers/specs/2026-04-24-dark-factory-design.md`

**Testing note:** per spec, no Rails-side test suite for v1. Each task ends with a manual smoke test. Generated-code correctness is validated by the target repo's CI on the resulting PRs.

**Prerequisites on the host:**
- Rails 8.1 app is already scaffolded (this repo).
- Node 20+ installed (`node --version`).
- `gh` CLI installed and authenticated (`gh auth status`).
- `ANTHROPIC_API_KEY` available in the shell.
- Remote `origin` points to `git@github.com:cvandermeer/dark_factory_test.git`.

---

## Task 1: Node dependencies and environment setup

**Files:**
- Create: `package.json`
- Create: `.env.example`
- Modify: `.gitignore`

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "dark_factory_agent",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "description": "Node wrapper that runs the Claude Agent SDK on behalf of a Rails job.",
  "scripts": {
    "agent": "node script/run_agent.mjs"
  },
  "dependencies": {
    "@anthropic-ai/claude-agent-sdk": "^0.1.0"
  },
  "engines": {
    "node": ">=20"
  }
}
```

- [ ] **Step 2: Install Node dependencies**

Run: `npm install`
Expected: `node_modules/` created, `package-lock.json` created, no errors.

If the `@anthropic-ai/claude-agent-sdk` version pinned above doesn't resolve, run `npm view @anthropic-ai/claude-agent-sdk version` to find the latest and pin that.

- [ ] **Step 3: Add `node_modules/` and `.env` to `.gitignore`**

Append to `.gitignore`:

```
# Node
/node_modules
/npm-debug.log

# Local env
/.env

# Worktrees created by DarkFactoryJob (lives as a sibling directory, not inside this repo,
# but ignore the symlink/target if someone puts it here by mistake)
/df_work
```

- [ ] **Step 4: Create `.env.example`**

```
ANTHROPIC_API_KEY=sk-ant-...
GH_TOKEN=ghp_...
```

Create a local `.env` (not committed) with real values. Rails auto-loads `.env` via... actually, Rails does not load `.env` by default. Add the `dotenv-rails` gem in the next step.

- [ ] **Step 5: Add `dotenv-rails` gem**

Modify `Gemfile` — add inside the `group :development, :test do` block:

```ruby
  gem "dotenv-rails"
```

Run: `bundle install`
Expected: bundle resolves cleanly.

- [ ] **Step 6: Verify env loads**

Create local `.env` with real `ANTHROPIC_API_KEY` and `GH_TOKEN`. Then:

Run: `bin/rails runner 'puts ENV["ANTHROPIC_API_KEY"]&.slice(0, 10)'`
Expected: prints the first 10 chars of your key (e.g., `sk-ant-...`).

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json .gitignore .env.example Gemfile Gemfile.lock
git commit -m "chore: add Node deps and env loading for dark factory"
```

---

## Task 2: `FeatureRequest` model and migration

**Files:**
- Create: `db/migrate/<timestamp>_create_feature_requests.rb` (via generator)
- Create: `app/models/feature_request.rb` (via generator, then edit)

- [ ] **Step 1: Generate model**

Run: `bin/rails g model FeatureRequest title:string body:text status:string branch_name:string pr_url:string pr_merged_at:datetime failure_reason:text`
Expected: migration + model file created.

- [ ] **Step 2: Edit the migration**

Open the new `db/migrate/<timestamp>_create_feature_requests.rb` and replace with:

```ruby
class CreateFeatureRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :feature_requests do |t|
      t.string :title, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "todo"
      t.string :branch_name
      t.string :pr_url
      t.datetime :pr_merged_at
      t.text :failure_reason

      t.timestamps
    end

    add_index :feature_requests, :status
  end
end
```

- [ ] **Step 3: Edit the model**

Replace `app/models/feature_request.rb`:

```ruby
class FeatureRequest < ApplicationRecord
  STATUSES = %w[todo doing to_review failed].freeze

  has_many :agent_events, -> { order(:sequence) }, dependent: :destroy

  validates :title, presence: true, length: { maximum: 200 }
  validates :body, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :todo,      -> { where(status: "todo") }
  scope :doing,     -> { where(status: "doing") }
  scope :to_review, -> { where(status: "to_review") }
  scope :failed,    -> { where(status: "failed") }

  def slug
    title.parameterize.presence || "untitled"
  end

  def branch
    branch_name || "feature-request/#{id}-#{slug}"
  end
end
```

- [ ] **Step 4: Run migration**

Run: `bin/rails db:migrate`
Expected: `feature_requests` table created.

- [ ] **Step 5: Smoke test**

Run: `bin/rails runner 'fr = FeatureRequest.create!(title: "Test", body: "Hello"); puts fr.status; puts fr.branch'`
Expected output:
```
todo
feature-request/1-test
```

- [ ] **Step 6: Clean up the smoke test record**

Run: `bin/rails runner 'FeatureRequest.destroy_all'`

- [ ] **Step 7: Commit**

```bash
git add db/migrate/*create_feature_requests.rb app/models/feature_request.rb db/schema.rb
git commit -m "feat: add FeatureRequest model"
```

---

## Task 3: `AgentEvent` model and migration

**Files:**
- Create: `db/migrate/<timestamp>_create_agent_events.rb`
- Create: `app/models/agent_event.rb`

- [ ] **Step 1: Generate model**

Run: `bin/rails g model AgentEvent feature_request:references kind:string payload:json sequence:integer`
Expected: migration + model file created.

- [ ] **Step 2: Edit the migration**

Replace:

```ruby
class CreateAgentEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_events do |t|
      t.references :feature_request, null: false, foreign_key: true
      t.string :kind, null: false
      t.json :payload, null: false
      t.integer :sequence, null: false

      t.timestamps
    end

    add_index :agent_events, [:feature_request_id, :sequence], unique: true
  end
end
```

Note: sqlite doesn't have JSONB; `json` column type maps to sqlite's native JSON support in Rails 8.

- [ ] **Step 3: Edit the model**

Replace `app/models/agent_event.rb`:

```ruby
class AgentEvent < ApplicationRecord
  KINDS = %w[text tool_use tool_result system error].freeze

  belongs_to :feature_request

  validates :kind, inclusion: { in: KINDS }
  validates :sequence, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :in_order, -> { order(:sequence) }
end
```

- [ ] **Step 4: Run migration and smoke test**

Run:
```bash
bin/rails db:migrate
bin/rails runner '
  fr = FeatureRequest.create!(title: "Test", body: "Hi")
  AgentEvent.create!(feature_request: fr, kind: "text", payload: { content: "hello" }, sequence: 0)
  AgentEvent.create!(feature_request: fr, kind: "tool_use", payload: { tool: "Read", args: { path: "x.rb" } }, sequence: 1)
  puts fr.agent_events.count
  puts fr.agent_events.first.payload.inspect
  FeatureRequest.destroy_all
'
```
Expected: `2` and a hash like `{"content"=>"hello"}`.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/*create_agent_events.rb app/models/agent_event.rb db/schema.rb
git commit -m "feat: add AgentEvent model"
```

---

## Task 4: Kanban board UI (static — no streaming yet)

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/feature_requests_controller.rb`
- Create: `app/views/feature_requests/index.html.erb`
- Create: `app/views/feature_requests/_card.html.erb`
- Create: `app/views/feature_requests/_form.html.erb`
- Modify: `app/assets/stylesheets/application.css`

- [ ] **Step 1: Add routes**

Replace `config/routes.rb` with:

```ruby
Rails.application.routes.draw do
  root "feature_requests#index"
  resources :feature_requests, only: [:index, :show, :create, :destroy]

  get "up" => "rails/health#show", as: :rails_health_check
end
```

- [ ] **Step 2: Create controller**

Create `app/controllers/feature_requests_controller.rb`:

```ruby
class FeatureRequestsController < ApplicationController
  def index
    @feature_requests = FeatureRequest.order(created_at: :desc)
    @feature_request = FeatureRequest.new
  end

  def show
    @feature_request = FeatureRequest.find(params[:id])
    @events = @feature_request.agent_events.in_order
  end

  def create
    @feature_request = FeatureRequest.new(feature_request_params)
    if @feature_request.save
      redirect_to root_path
    else
      @feature_requests = FeatureRequest.order(created_at: :desc)
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    FeatureRequest.find(params[:id]).destroy
    redirect_to root_path
  end

  private

  def feature_request_params
    params.require(:feature_request).permit(:title, :body)
  end
end
```

- [ ] **Step 3: Create card partial**

Create `app/views/feature_requests/_card.html.erb`:

```erb
<%= tag.div id: dom_id(feature_request), class: "fr-card fr-card--#{feature_request.status}" do %>
  <%= link_to feature_request, class: "fr-card__link" do %>
    <div class="fr-card__title"><%= feature_request.title %></div>
    <div class="fr-card__body"><%= truncate(feature_request.body, length: 120) %></div>

    <% case feature_request.status %>
    <% when "doing" %>
      <div class="fr-card__status">
        <span class="fr-spinner"></span> running…
      </div>
    <% when "to_review" %>
      <div class="fr-card__status">
        <% if feature_request.pr_url.present? %>
          <a href="<%= feature_request.pr_url %>" target="_blank" rel="noopener">PR ↗</a>
        <% end %>
        <% if feature_request.pr_merged_at.present? %>
          <span class="fr-merged">✓ merged</span>
        <% end %>
      </div>
    <% when "failed" %>
      <div class="fr-card__status fr-card__status--failed">
        <%= truncate(feature_request.failure_reason.to_s, length: 80) %>
      </div>
    <% end %>
  <% end %>

  <% if %w[to_review failed].include?(feature_request.status) %>
    <%= button_to "Delete", feature_request, method: :delete,
                  data: { turbo_confirm: "Remove this card? (Does not touch GitHub.)" },
                  class: "fr-card__delete" %>
  <% end %>
<% end %>
```

- [ ] **Step 4: Create form partial**

Create `app/views/feature_requests/_form.html.erb`:

```erb
<%= form_with(model: feature_request, class: "fr-form") do |f| %>
  <% if feature_request.errors.any? %>
    <div class="fr-errors">
      <% feature_request.errors.full_messages.each do |msg| %>
        <div><%= msg %></div>
      <% end %>
    </div>
  <% end %>

  <div>
    <%= f.label :title %>
    <%= f.text_field :title, placeholder: "One-line summary of the feature" %>
  </div>
  <div>
    <%= f.label :body %>
    <%= f.text_area :body, rows: 4, placeholder: "Details — what should the AI build?" %>
  </div>
  <div>
    <%= f.submit "Submit feature request" %>
  </div>
<% end %>
```

- [ ] **Step 5: Create the index view**

Create `app/views/feature_requests/index.html.erb`:

```erb
<section class="fr-submit">
  <h2>Submit a feature request</h2>
  <%= render "form", feature_request: @feature_request %>
</section>

<section class="fr-board">
  <% %w[todo doing to_review failed].each do |col| %>
    <div class="fr-column">
      <h3 class="fr-column__title"><%= col.humanize %></h3>
      <div class="fr-column__cards">
        <% @feature_requests.select { |fr| fr.status == col }.each do |fr| %>
          <%= render "card", feature_request: fr %>
        <% end %>
      </div>
    </div>
  <% end %>
</section>
```

- [ ] **Step 6: Add basic CSS**

Append to `app/assets/stylesheets/application.css`:

```css
body {
  font-family: system-ui, -apple-system, sans-serif;
  margin: 0;
  padding: 20px;
  background: #fafafa;
  color: #222;
}

.fr-submit {
  max-width: 640px;
  margin: 0 auto 32px;
  background: white;
  border: 1px solid #e5e5e5;
  border-radius: 8px;
  padding: 20px;
}

.fr-submit h2 { margin-top: 0; }

.fr-form div { margin-bottom: 12px; }
.fr-form label { display: block; margin-bottom: 4px; font-weight: 600; font-size: 13px; }
.fr-form input[type="text"],
.fr-form textarea {
  width: 100%;
  padding: 8px;
  border: 1px solid #ccc;
  border-radius: 4px;
  font-family: inherit;
  font-size: 14px;
  box-sizing: border-box;
}
.fr-form input[type="submit"] {
  background: #111;
  color: white;
  border: none;
  padding: 10px 16px;
  border-radius: 4px;
  cursor: pointer;
  font-weight: 600;
}

.fr-errors { color: #b00020; margin-bottom: 12px; }

.fr-board {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 16px;
  max-width: 1400px;
  margin: 0 auto;
}

.fr-column {
  background: #f0f0f0;
  border-radius: 8px;
  padding: 12px;
  min-height: 400px;
}

.fr-column__title {
  margin: 0 0 12px;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: #555;
}

.fr-column__cards { display: flex; flex-direction: column; gap: 8px; }

.fr-card {
  background: white;
  border: 1px solid #e5e5e5;
  border-radius: 6px;
  padding: 10px 12px;
  box-shadow: 0 1px 2px rgba(0,0,0,0.04);
  position: relative;
}
.fr-card--doing { border-left: 3px solid #3b82f6; }
.fr-card--to_review { border-left: 3px solid #10b981; }
.fr-card--failed { border-left: 3px solid #ef4444; background: #fff5f5; }

.fr-card__link { display: block; text-decoration: none; color: inherit; }
.fr-card__title { font-weight: 600; font-size: 14px; margin-bottom: 4px; }
.fr-card__body { font-size: 13px; color: #555; margin-bottom: 6px; }
.fr-card__status { font-size: 12px; color: #666; }
.fr-card__status--failed { color: #b00020; }
.fr-merged { color: #10b981; margin-left: 6px; }

.fr-spinner {
  display: inline-block; width: 10px; height: 10px;
  border: 2px solid #3b82f6; border-top-color: transparent;
  border-radius: 50%;
  animation: fr-spin 0.8s linear infinite;
  vertical-align: middle; margin-right: 4px;
}
@keyframes fr-spin { to { transform: rotate(360deg); } }

.fr-card__delete {
  position: absolute; top: 6px; right: 6px;
  background: transparent; border: none; cursor: pointer;
  font-size: 11px; color: #999;
}
.fr-card__delete:hover { color: #b00020; }
```

- [ ] **Step 7: Smoke test**

Run: `bin/rails s`
Open: http://localhost:3000/

Expected:
- Submit form at top.
- Four empty columns labeled Todo / Doing / To review / Failed.
- Submit a request — after redirect, a card appears in the Todo column with the title and body.

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/feature_requests_controller.rb app/views/feature_requests app/assets/stylesheets/application.css
git commit -m "feat: add Kanban board UI and submission form"
```

---

## Task 5: Feature request detail view + event rendering partial

**Files:**
- Create: `app/views/feature_requests/show.html.erb`
- Create: `app/views/agent_events/_event.html.erb`

- [ ] **Step 1: Create event partial**

Create `app/views/agent_events/_event.html.erb`:

```erb
<% payload = event.payload || {} %>

<%= tag.div id: dom_id(event), class: "ae ae--#{event.kind}" do %>
  <div class="ae__meta">#<%= event.sequence %> · <%= event.kind %></div>

  <% case event.kind %>
  <% when "text" %>
    <div class="ae__text"><%= simple_format(payload["content"].to_s) %></div>

  <% when "tool_use" %>
    <details class="ae__tool">
      <summary>🔧 <%= payload["tool"] %>(<%= (payload["args"] || {}).keys.join(", ") %>)</summary>
      <pre><%= JSON.pretty_generate(payload["args"] || {}) %></pre>
    </details>

  <% when "tool_result" %>
    <details class="ae__tool">
      <summary>← result (<%= payload["tool"] %>)</summary>
      <pre><%= truncate(payload["output"].to_s, length: 4000) %></pre>
    </details>

  <% when "error" %>
    <div class="ae__error"><%= payload["message"] %></div>

  <% when "system" %>
    <div class="ae__system"><%= payload["message"] %></div>
  <% end %>
<% end %>
```

- [ ] **Step 2: Create show view**

Create `app/views/feature_requests/show.html.erb`:

```erb
<div class="fr-show">
  <nav><%= link_to "← Board", root_path %></nav>

  <header>
    <h1><%= @feature_request.title %></h1>
    <div class="fr-show__status">Status: <strong><%= @feature_request.status %></strong></div>
    <% if @feature_request.pr_url.present? %>
      <a href="<%= @feature_request.pr_url %>" target="_blank" rel="noopener">Open PR ↗</a>
      <% if @feature_request.pr_merged_at.present? %>
        <span class="fr-merged">✓ merged <%= time_ago_in_words(@feature_request.pr_merged_at) %> ago</span>
      <% end %>
    <% end %>
    <% if @feature_request.failure_reason.present? %>
      <div class="fr-show__failure">
        <strong>Failure:</strong>
        <pre><%= @feature_request.failure_reason %></pre>
      </div>
    <% end %>
  </header>

  <section class="fr-show__body">
    <h3>Request</h3>
    <div><%= simple_format(@feature_request.body) %></div>
  </section>

  <section class="fr-show__events">
    <h3>Agent events</h3>
    <div id="fr-<%= @feature_request.id %>-events" class="ae-stream">
      <%= render @events %>
    </div>
  </section>
</div>
```

- [ ] **Step 3: Add CSS for show view**

Append to `app/assets/stylesheets/application.css`:

```css
.fr-show {
  max-width: 900px;
  margin: 0 auto;
  background: white;
  border: 1px solid #e5e5e5;
  border-radius: 8px;
  padding: 24px;
}
.fr-show nav { margin-bottom: 12px; font-size: 13px; }
.fr-show header h1 { margin: 0 0 8px; }
.fr-show__failure { margin-top: 12px; color: #b00020; }
.fr-show__failure pre { background: #fff5f5; padding: 8px; border-radius: 4px; overflow: auto; font-size: 12px; }
.fr-show__body { margin: 24px 0; }
.fr-show__events h3 { margin-bottom: 8px; }

.ae-stream {
  background: #fafafa;
  border: 1px solid #e5e5e5;
  border-radius: 6px;
  padding: 8px;
  max-height: 600px;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.ae { font-size: 13px; padding: 6px 8px; background: white; border-radius: 4px; border: 1px solid #eee; }
.ae__meta { font-size: 10px; color: #999; text-transform: uppercase; margin-bottom: 2px; }
.ae__text { white-space: pre-wrap; }
.ae--error { background: #fff5f5; border-color: #fecaca; }
.ae__error { color: #b00020; }
.ae__system { color: #666; font-style: italic; }
.ae__tool pre { background: #f5f5f5; padding: 6px; border-radius: 3px; font-size: 11px; overflow-x: auto; }
.ae__tool summary { cursor: pointer; user-select: none; }
```

- [ ] **Step 4: Smoke test**

Run: `bin/rails s` (if not already running)
Navigate: click the card created in Task 4.

Expected:
- Detail view shows title, status, request body.
- "Agent events" section is empty (no events yet).
- "← Board" link returns to index.

Create a synthetic event to verify rendering:

```bash
bin/rails runner '
  fr = FeatureRequest.first
  fr.agent_events.create!(kind: "text", payload: { content: "hello world" }, sequence: 0)
  fr.agent_events.create!(kind: "tool_use", payload: { tool: "Read", args: { path: "app/models/x.rb" } }, sequence: 1)
'
```

Reload the show page — the two events render. Clean up: `bin/rails runner 'FeatureRequest.destroy_all'`.

- [ ] **Step 5: Commit**

```bash
git add app/views/feature_requests/show.html.erb app/views/agent_events app/assets/stylesheets/application.css
git commit -m "feat: add feature request detail view with event log"
```

---

## Task 6: `DarkFactoryJob` skeleton with fake lifecycle

The goal here is a working status-transition pipeline with no real agent yet. The job just sleeps and moves the status through `todo → doing → to_review`. Real agent invocation comes later.

**Files:**
- Create: `app/jobs/dark_factory_job.rb`
- Modify: `app/models/feature_request.rb` (enqueue after_create_commit)
- Modify: `config/environments/development.rb` (run jobs inline? no — we want SolidQueue async)

- [ ] **Step 1: Create the job**

Create `app/jobs/dark_factory_job.rb`:

```ruby
class DarkFactoryJob < ApplicationJob
  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)

    Rails.logger.info("[DarkFactory] starting FR##{fr.id}: #{fr.title}")
    fr.update!(status: "doing")

    # --- placeholder for real agent run (Task 9+) ---
    sleep 3
    fr.agent_events.create!(
      kind: "system",
      payload: { message: "Fake run — agent not implemented yet" },
      sequence: 0
    )
    sleep 2
    # --- end placeholder ---

    fr.update!(
      status: "to_review",
      branch_name: fr.branch,
      pr_url: "https://github.com/cvandermeer/dark_factory_test/pull/fake"
    )
    Rails.logger.info("[DarkFactory] finished FR##{fr.id}")
  rescue => e
    fr&.update!(status: "failed", failure_reason: "job_crashed: #{e.class}: #{e.message}")
    raise
  end
end
```

- [ ] **Step 2: Enqueue the job on FR creation**

Modify `app/models/feature_request.rb` — add at the bottom of the class (before the closing `end`):

```ruby
  after_create_commit :enqueue_dark_factory_job

  private

  def enqueue_dark_factory_job
    DarkFactoryJob.perform_later(id)
  end
```

- [ ] **Step 3: Start SolidQueue**

In a second terminal:

Run: `bin/jobs`
Expected: SolidQueue boots and logs "Worker started" or similar.

(If `bin/jobs` doesn't exist, run `bin/rails solid_queue:start` or verify SolidQueue is set up in `config/queue.yml`.)

- [ ] **Step 4: Smoke test**

With Rails server + `bin/jobs` both running, open http://localhost:3000/ and submit a feature request.

Expected:
- Card appears in Todo column.
- Within ~1s, reload — card is in Doing (the job flipped status after 0s sleep, then sleeps 3s).
- After ~5s total, reload — card is in To review with a fake PR URL.

No live streaming yet — we're reloading manually. That comes in Task 10.

- [ ] **Step 5: Clean up**

```bash
bin/rails runner 'FeatureRequest.destroy_all'
```

- [ ] **Step 6: Commit**

```bash
git add app/jobs/dark_factory_job.rb app/models/feature_request.rb
git commit -m "feat: add DarkFactoryJob skeleton with fake lifecycle"
```

---

## Task 7: Turbo Streams for card movements

Make cards move between columns live without reloading.

**Files:**
- Modify: `app/models/feature_request.rb`
- Modify: `app/views/feature_requests/index.html.erb`

- [ ] **Step 1: Broadcast on status change**

Modify `app/models/feature_request.rb` — add near the top of the class (below the associations):

```ruby
  after_create_commit  -> { broadcast_prepend_to "board", target: "fr-column-todo", partial: "feature_requests/card", locals: { feature_request: self } }
  after_update_commit  :broadcast_card_refresh
  after_destroy_commit -> { broadcast_remove_to "board" }
```

Then add to the private section:

```ruby
  def broadcast_card_refresh
    # Replace card in place. CSS moves it between columns because the card
    # lives inside the column's cards container — we must instead remove
    # from its old location and insert into the new one if status changed.
    if saved_change_to_status?
      broadcast_remove_to "board"
      broadcast_prepend_to "board", target: "fr-column-#{status}", partial: "feature_requests/card", locals: { feature_request: self }
    else
      broadcast_replace_to "board", partial: "feature_requests/card", locals: { feature_request: self }
    end
  end
```

- [ ] **Step 2: Update index view with turbo stream subscription and column IDs**

Replace `app/views/feature_requests/index.html.erb`:

```erb
<%= turbo_stream_from "board" %>

<section class="fr-submit">
  <h2>Submit a feature request</h2>
  <%= render "form", feature_request: @feature_request %>
</section>

<section class="fr-board">
  <% %w[todo doing to_review failed].each do |col| %>
    <div class="fr-column">
      <h3 class="fr-column__title"><%= col.humanize %></h3>
      <div id="fr-column-<%= col %>" class="fr-column__cards">
        <% @feature_requests.select { |fr| fr.status == col }.each do |fr| %>
          <%= render "card", feature_request: fr %>
        <% end %>
      </div>
    </div>
  <% end %>
</section>
```

- [ ] **Step 3: Smoke test**

Run Rails + `bin/jobs`, open http://localhost:3000/ in two browser tabs (or one is fine).

Submit a request.

Expected:
- Card appears in Todo **without reloading** (Turbo Stream prepend).
- ~1s later it disappears from Todo and shows up in Doing, live.
- ~5s total later it moves to To review, live.

- [ ] **Step 4: Commit**

```bash
git add app/models/feature_request.rb app/views/feature_requests/index.html.erb
git commit -m "feat: live board updates via Turbo Streams"
```

---

## Task 8: `WorktreeManager` service

Encapsulates `git worktree add`/`remove`. Keeps the job clean.

**Files:**
- Create: `app/services/worktree_manager.rb`

- [ ] **Step 1: Create the service**

Create `app/services/worktree_manager.rb`:

```ruby
class WorktreeManager
  class Error < StandardError; end

  attr_reader :path, :branch

  # repo_root: path to the main checkout.
  # branch:    name of the branch to create.
  # base:      base branch to fork from (default "main").
  def initialize(repo_root:, branch:, base: "main")
    @repo_root = repo_root
    @branch = branch
    @base = base
    @path = File.expand_path("../df_work/fr-#{SecureRandom.hex(4)}", repo_root)
  end

  def setup!
    FileUtils.mkdir_p(File.dirname(@path))
    run!("git", "-C", @repo_root, "worktree", "add", "-b", @branch, @path, @base)
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

- [ ] **Step 2: Smoke test**

Run:
```bash
bin/rails runner '
  wm = WorktreeManager.new(repo_root: Rails.root.to_s, branch: "test-worktree-#{Time.now.to_i}")
  puts "Setting up worktree at #{wm.path}..."
  wm.setup!
  puts "Worktree exists: #{File.directory?(wm.path)}"
  puts "Branch file: #{File.exist?(File.join(wm.path, "Gemfile"))}"
  wm.teardown!
  puts "After teardown, worktree exists: #{File.directory?(wm.path)}"
'
```

Expected:
```
Setting up worktree at .../df_work/fr-XXXXXXXX...
Worktree exists: true
Branch file: true
After teardown, worktree exists: false
```

Prune any leftover branches: `git branch | grep test-worktree- | xargs git branch -D 2>/dev/null || true`

- [ ] **Step 3: Commit**

```bash
git add app/services/worktree_manager.rb
git commit -m "feat: add WorktreeManager service"
```

---

## Task 9: Node agent script — `script/run_agent.mjs`

The Node subprocess. Reads a JSON blob from stdin (FR title + body), runs the Claude Agent SDK with `bypassPermissions`, emits NDJSON events to stdout. Does NOT push or open a PR.

**Files:**
- Create: `script/run_agent.mjs`

- [ ] **Step 1: Verify the SDK's `query` interface**

Run: `node -e "import('@anthropic-ai/claude-agent-sdk').then(m => console.log(Object.keys(m)))"`
Expected: prints an array including `query` (and possibly `tool`, `createSdkMcpServer`, etc.).

If `query` isn't there, consult the SDK's docs for the current entry point.

- [ ] **Step 2: Create the script**

Create `script/run_agent.mjs`:

```javascript
#!/usr/bin/env node
// Runs a Claude Agent SDK session inside a pre-existing worktree.
// Reads {title, body} as JSON from stdin.
// Writes one JSON event per line to stdout.
// Exits 0 on success, nonzero on error. Does not push or open a PR.

import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import process from "node:process";

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function parseArgs(argv) {
  const args = { worktree: null };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--worktree") args.worktree = argv[++i];
  }
  if (!args.worktree) {
    console.error("usage: run_agent.mjs --worktree <path>");
    process.exit(2);
  }
  return args;
}

const { worktree } = parseArgs(process.argv);
const stdin = readFileSync(0, "utf-8");
const { title, body } = JSON.parse(stdin);

const systemPrompt = [
  "You are a software engineer working in a Rails 8 app.",
  "Implement the feature described below in the current directory.",
  "When finished, commit your changes with a clear message using git.",
  "Do NOT push the branch and do NOT open a pull request — the caller handles that.",
].join(" ");

const userPrompt = `Feature request:\n\nTitle: ${title}\n\nBody:\n${body}`;

process.chdir(worktree);

try {
  const iterator = query({
    prompt: userPrompt,
    options: {
      systemPrompt,
      permissionMode: "bypassPermissions",
      cwd: worktree,
    },
  });

  for await (const message of iterator) {
    // Forward every SDK message as-is. Rails will classify kind on ingest.
    emit({ raw: message });
  }
  emit({ raw: { type: "done" } });
  process.exit(0);
} catch (err) {
  emit({ raw: { type: "error", error: { name: err.name, message: err.message, stack: err.stack } } });
  process.exit(1);
}
```

- [ ] **Step 3: Smoke test — dry run against a throwaway worktree**

```bash
# Create a throwaway worktree manually
git worktree add ../df_work/smoke-test -b smoke-test main

# Pipe a tiny request
echo '{"title":"Add a TODO to README","body":"Append a line \"- [ ] make coffee\" to README.md"}' \
  | ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" node script/run_agent.mjs --worktree ../df_work/smoke-test
```

Expected:
- NDJSON events stream to stdout (one JSON object per line).
- Script exits 0.
- The worktree at `../df_work/smoke-test` has a new commit modifying `README.md`.

Verify:
```bash
cd ../df_work/smoke-test && git log --oneline -2 && cd -
```

Clean up:
```bash
git worktree remove --force ../df_work/smoke-test
git branch -D smoke-test
```

- [ ] **Step 4: Commit**

```bash
git add script/run_agent.mjs
git commit -m "feat: add Node Claude Agent SDK runner script"
```

---

## Task 10: `AgentRunner` service — spawn Node, parse stdout, persist events, broadcast

**Files:**
- Create: `app/services/agent_runner.rb`

- [ ] **Step 1: Create the service**

Create `app/services/agent_runner.rb`:

```ruby
class AgentRunner
  class AgentFailed < StandardError; end
  class Timeout < StandardError; end

  DEFAULT_TIMEOUT = 15 * 60 # seconds

  def initialize(feature_request:, worktree_path:, timeout: DEFAULT_TIMEOUT)
    @fr = feature_request
    @worktree = worktree_path
    @timeout = timeout
    @sequence = @fr.agent_events.maximum(:sequence).to_i + 1
  end

  def run!
    stdin_payload = JSON.dump(title: @fr.title, body: @fr.body)
    cmd = ["node", Rails.root.join("script/run_agent.mjs").to_s, "--worktree", @worktree]
    env = { "ANTHROPIC_API_KEY" => ENV["ANTHROPIC_API_KEY"] }

    Rails.logger.info("[AgentRunner] spawning: #{cmd.join(' ')}")
    stderr_buf = +""
    exit_status = nil

    Open3.popen3(env, *cmd, chdir: Rails.root.to_s) do |stdin, stdout, stderr, wait_thr|
      stdin.write(stdin_payload)
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
      tail = stderr_buf.lines.last(40).join
      raise AgentFailed, "agent_exited: #{exit_status}\n#{tail}"
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

  # Best-effort mapping from SDK message shapes to our event kinds.
  # Whatever we don't recognize, we store as "system" with the raw payload.
  def classify(msg)
    case msg["type"]
    when "assistant", "text"
      content = extract_text(msg)
      ["text", { "content" => content }]
    when "tool_use"
      ["tool_use", { "tool" => msg["name"], "args" => msg["input"] }]
    when "tool_result"
      ["tool_result", { "tool" => msg["name"], "output" => stringify_output(msg["content"]) }]
    when "error"
      ["error", { "message" => msg.dig("error", "message") || msg["message"].to_s }]
    when "done"
      ["system", { "message" => "agent finished" }]
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

- [ ] **Step 2: Smoke test (without wiring into job yet)**

Manually set up a worktree and run the service:

```bash
bin/rails runner '
  fr = FeatureRequest.create!(title: "Append TODO to README", body: "Append a line \"- [ ] make coffee\" to README.md")
  wm = WorktreeManager.new(repo_root: Rails.root.to_s, branch: "fr-smoke-#{fr.id}")
  wm.setup!
  begin
    AgentRunner.new(feature_request: fr, worktree_path: wm.path).run!
    puts "Events: #{fr.agent_events.count}"
    puts "First event kind: #{fr.agent_events.first.kind}"
  ensure
    wm.teardown!
    fr.destroy
  end
'
```

Expected:
- Events: >0 (typically 5–30 depending on how the agent decides to implement it).
- Multiple event kinds: some `text`, `tool_use`, `tool_result`.
- No exceptions.

Prune leftover branches if needed.

- [ ] **Step 3: Commit**

```bash
git add app/services/agent_runner.rb
git commit -m "feat: add AgentRunner service spawning Node agent subprocess"
```

---

## Task 11: `PrCreator` service — push + `gh pr create`

**Files:**
- Create: `app/services/pr_creator.rb`

- [ ] **Step 1: Create the service**

Create `app/services/pr_creator.rb`:

```ruby
class PrCreator
  class Error < StandardError; end

  def initialize(feature_request:, worktree_path:, base: "main")
    @fr = feature_request
    @worktree = worktree_path
    @base = base
  end

  # Returns the PR URL on success. Raises Error on failure.
  def create!
    push!
    open_pr!
  end

  private

  def push!
    run!("git", "-C", @worktree, "push", "-u", "origin", @fr.branch)
  end

  def open_pr!
    body = "#{@fr.body}\n\nRef: FR-#{@fr.id}"
    out = run!(
      "gh", "pr", "create",
      "--repo", origin_slug,
      "--base", @base,
      "--head", @fr.branch,
      "--title", @fr.title,
      "--body", body
    )
    url = out.strip.split("\n").find { |l| l.start_with?("https://") }
    raise Error, "could not parse PR URL from gh output:\n#{out}" unless url
    url
  end

  def origin_slug
    out = run!("git", "-C", @worktree, "remote", "get-url", "origin")
    # e.g. git@github.com:cvandermeer/dark_factory_test.git → cvandermeer/dark_factory_test
    out.strip.sub(%r{^.*github\.com[:/]}, "").sub(/\.git$/, "")
  end

  def run!(*cmd)
    env = { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact
    out, err, status = Open3.capture3(env, *cmd)
    raise Error, "#{cmd.join(' ')}: exit #{status.exitstatus}\n#{err}" unless status.success?
    out
  end
end
```

- [ ] **Step 2: Smoke test**

Create a branch with a dummy commit, then run PrCreator. The agent smoke test from Task 10 should have left you with experience — do similar here:

```bash
bin/rails runner '
  fr = FeatureRequest.create!(title: "Dummy PR test", body: "Just a smoke test for PrCreator")
  wm = WorktreeManager.new(repo_root: Rails.root.to_s, branch: "fr-prtest-#{fr.id}")
  wm.setup!
  begin
    File.write(File.join(wm.path, "SMOKE.md"), "smoke test\n")
    system("git", "-C", wm.path, "add", "SMOKE.md")
    system("git", "-C", wm.path, "commit", "-m", "smoke test")
    url = PrCreator.new(feature_request: fr, worktree_path: wm.path).create!
    puts "PR: #{url}"
  ensure
    wm.teardown!
    fr.destroy
  end
'
```

Expected: prints a PR URL. Go to the URL in a browser — verify PR exists and is open.

**Clean up after:** close the PR and delete the branch on GitHub:
```bash
gh pr close <pr-number> --delete-branch
```

- [ ] **Step 3: Commit**

```bash
git add app/services/pr_creator.rb
git commit -m "feat: add PrCreator service for push + gh pr create"
```

---

## Task 12: Wire everything into `DarkFactoryJob`

Replace the fake placeholder with real agent + PR creation.

**Files:**
- Modify: `app/jobs/dark_factory_job.rb`

- [ ] **Step 1: Replace the job**

Replace `app/jobs/dark_factory_job.rb`:

```ruby
class DarkFactoryJob < ApplicationJob
  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)
    fr.update!(status: "doing", branch_name: fr.branch)

    worktree = WorktreeManager.new(repo_root: Rails.root.to_s, branch: fr.branch)
    worktree.setup!

    begin
      AgentRunner.new(feature_request: fr, worktree_path: worktree.path).run!
      pr_url = PrCreator.new(feature_request: fr, worktree_path: worktree.path).create!
      fr.update!(status: "to_review", pr_url: pr_url)
    rescue AgentRunner::Timeout
      fr.update!(status: "failed", failure_reason: "budget_exceeded: 15 min")
    rescue AgentRunner::AgentFailed => e
      fr.update!(status: "failed", failure_reason: e.message)
    rescue PrCreator::Error => e
      fr.update!(status: "failed", failure_reason: "push_failed: #{e.message}")
    ensure
      worktree.teardown!
    end
  rescue => e
    fr&.update!(status: "failed", failure_reason: "job_crashed: #{e.class}: #{e.message}")
    raise
  end
end
```

- [ ] **Step 2: End-to-end smoke test**

Start Rails + jobs, open the board, submit a small feature request. For example:
- Title: `Append TODO to README`
- Body: `Append a line "- [ ] make coffee" to README.md`

Expected:
- Card appears in Todo.
- Within ~1s, moves to Doing.
- Detail view (click card) shows events streaming live.
- Within ~2–5 minutes, card moves to To review with a real PR link.
- Click the PR link — PR exists on GitHub against `main`, diff contains the README change.

Clean up:
```bash
gh pr close <pr-number> --delete-branch
bin/rails runner 'FeatureRequest.destroy_all'
git branch | grep feature-request/ | xargs git branch -D 2>/dev/null || true
```

- [ ] **Step 3: Commit**

```bash
git add app/jobs/dark_factory_job.rb
git commit -m "feat: wire DarkFactoryJob to run agent and open PR"
```

---

## Task 13: Turbo Streams subscription on the detail page for live event appends

The `AgentRunner` already broadcasts `broadcast_append_to "feature_request_<id>_events"`. Now subscribe the show page to that stream.

**Files:**
- Modify: `app/views/feature_requests/show.html.erb`

- [ ] **Step 1: Add `turbo_stream_from` to the show view**

At the top of `app/views/feature_requests/show.html.erb`, add:

```erb
<%= turbo_stream_from "feature_request_#{@feature_request.id}_events" %>
<%= turbo_stream_from "board" %>
```

(The `"board"` subscription means status changes — e.g., running → to_review — reflect in the header without a page reload. We already have the model broadcasts from Task 7.)

Wait — the `"board"` broadcasts from Task 7 target the column containers on the index page, not the header on the show page. For the show page, we want the status header to update. Add a dedicated stream for this.

Instead, replace the show view's status header area with a targetable partial. Modify `app/views/feature_requests/show.html.erb` so the header region has a targetable ID:

```erb
<%= turbo_stream_from "feature_request_#{@feature_request.id}_events" %>
<%= turbo_stream_from "feature_request_#{@feature_request.id}" %>

<div class="fr-show">
  <nav><%= link_to "← Board", root_path %></nav>

  <div id="<%= dom_id(@feature_request, :header) %>">
    <%= render "header", feature_request: @feature_request %>
  </div>

  <section class="fr-show__body">
    <h3>Request</h3>
    <div><%= simple_format(@feature_request.body) %></div>
  </section>

  <section class="fr-show__events">
    <h3>Agent events</h3>
    <div id="fr-<%= @feature_request.id %>-events" class="ae-stream">
      <%= render @events %>
    </div>
  </section>
</div>
```

- [ ] **Step 2: Extract the header partial**

Create `app/views/feature_requests/_header.html.erb`:

```erb
<header>
  <h1><%= feature_request.title %></h1>
  <div class="fr-show__status">Status: <strong><%= feature_request.status %></strong></div>
  <% if feature_request.pr_url.present? %>
    <a href="<%= feature_request.pr_url %>" target="_blank" rel="noopener">Open PR ↗</a>
    <% if feature_request.pr_merged_at.present? %>
      <span class="fr-merged">✓ merged <%= time_ago_in_words(feature_request.pr_merged_at) %> ago</span>
    <% end %>
  <% end %>
  <% if feature_request.failure_reason.present? %>
    <div class="fr-show__failure">
      <strong>Failure:</strong>
      <pre><%= feature_request.failure_reason %></pre>
    </div>
  <% end %>
</header>
```

- [ ] **Step 3: Broadcast header updates on model change**

Modify `app/models/feature_request.rb` — add to the `broadcast_card_refresh` method (after the existing logic) so it also broadcasts the header replace:

```ruby
  def broadcast_card_refresh
    if saved_change_to_status?
      broadcast_remove_to "board"
      broadcast_prepend_to "board", target: "fr-column-#{status}", partial: "feature_requests/card", locals: { feature_request: self }
    else
      broadcast_replace_to "board", partial: "feature_requests/card", locals: { feature_request: self }
    end

    broadcast_replace_to(
      "feature_request_#{id}",
      target: ActionView::RecordIdentifier.dom_id(self, :header),
      partial: "feature_requests/header",
      locals: { feature_request: self }
    )
  end
```

- [ ] **Step 4: Smoke test**

Start Rails + `bin/jobs`. Submit a feature request, then immediately click the card to open the show page.

Expected:
- Status header reads "doing" and updates to "to_review" (or "failed") live without reloading.
- Events stream into the Agent events section in real time as the agent works.
- Reloading the show page mid-run preserves all prior events (replayed from DB) and continues tailing live.

Clean up after verification.

- [ ] **Step 5: Commit**

```bash
git add app/views/feature_requests/show.html.erb app/views/feature_requests/_header.html.erb app/models/feature_request.rb
git commit -m "feat: live-stream agent events and status on detail page"
```

---

## Task 14: `PollMergedPrsJob` + SolidQueue recurring config

**Files:**
- Create: `app/jobs/poll_merged_prs_job.rb`
- Create or modify: `config/recurring.yml`

- [ ] **Step 1: Create the job**

Create `app/jobs/poll_merged_prs_job.rb`:

```ruby
class PollMergedPrsJob < ApplicationJob
  queue_as :default

  def perform
    FeatureRequest.to_review
                  .where.not(pr_url: nil)
                  .where(pr_merged_at: nil)
                  .find_each do |fr|
      check(fr)
    end
  end

  private

  def check(fr)
    out, _err, status = Open3.capture3(
      { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
      "gh", "pr", "view", fr.pr_url, "--json", "mergedAt,state"
    )
    return unless status.success?

    data = JSON.parse(out)
    merged_at = data["mergedAt"]
    if merged_at.present?
      fr.update!(pr_merged_at: Time.parse(merged_at))
    end
  rescue => e
    Rails.logger.warn("[PollMergedPrsJob] skipping FR##{fr.id}: #{e.class}: #{e.message}")
  end
end
```

- [ ] **Step 2: Register as a recurring task**

Create `config/recurring.yml`:

```yaml
production:
  poll_merged_prs:
    class: PollMergedPrsJob
    queue: default
    schedule: every 2 minutes

development:
  poll_merged_prs:
    class: PollMergedPrsJob
    queue: default
    schedule: every 2 minutes
```

(Adjust to your Rails/SolidQueue version if the schedule DSL differs — check `bin/jobs --help` or the SolidQueue README.)

- [ ] **Step 3: Smoke test**

You need an existing PR in `to_review` state. Either keep the one from Task 12's smoke test open, or submit a new request and let the factory produce one.

Then:
1. Merge the PR on GitHub manually.
2. Wait up to 2 minutes.
3. Reload the board — the card in "To review" should now show a ✓ merged indicator.

If you don't want to wait, run the job manually:
```bash
bin/rails runner 'PollMergedPrsJob.perform_now'
```

Expected: the `pr_merged_at` column populates for merged PRs.

Clean up any test PRs/branches.

- [ ] **Step 4: Commit**

```bash
git add app/jobs/poll_merged_prs_job.rb config/recurring.yml
git commit -m "feat: add PollMergedPrsJob recurring task for PR merge detection"
```

---

## Task 15: Final end-to-end demo test

**Files:** none — this is an end-to-end verification.

- [ ] **Step 1: Fresh state**

```bash
bin/rails runner 'FeatureRequest.destroy_all'
git branch | grep feature-request/ | xargs git branch -D 2>/dev/null || true
gh pr list --state open --json number,headRefName --jq '.[] | select(.headRefName | startswith("feature-request/")) | .number' | xargs -I {} gh pr close {} --delete-branch 2>/dev/null || true
```

- [ ] **Step 2: Start everything**

Two terminals:

Terminal A: `bin/rails s`
Terminal B: `bin/jobs`

- [ ] **Step 3: Submit a feature request**

Open http://localhost:3000/. Submit:
- Title: `Add a greeting helper`
- Body: `Add a simple ApplicationHelper method called "greeting" that returns a string like "Welcome to Dark Factory". Do not modify anything else.`

- [ ] **Step 4: Watch the magic**

- Card appears in Todo, immediately moves to Doing.
- Click the card — detail page shows agent events streaming live.
- After the agent finishes, card moves to To review with a PR link.
- Open the PR on GitHub — it exists, diff touches `app/helpers/application_helper.rb`.

- [ ] **Step 5: Merge → poll → card updates**

Merge the PR on GitHub. Wait up to 2 minutes (or trigger `PollMergedPrsJob.perform_now`). Card in "To review" now shows ✓ merged.

- [ ] **Step 6: Provoke a failure**

Submit a deliberately unreasonable request:
- Title: `This is impossible`
- Body: `Delete every file in /etc on the host.`

Expected: the agent either refuses, can't complete, or times out; card lands in Failed with a `failure_reason`.

- [ ] **Step 7: Done**

Demo ready. If anything is flaky, revisit the specific task and iterate there.

---

## Appendix — Troubleshooting

- **`bin/jobs` isn't picking up the job.** Check `config/queue.yml` has the default queue configured. Run `bin/rails solid_queue:install` if it's missing.
- **Turbo Streams don't arrive in the browser.** Check SolidCable is configured in `config/cable.yml`. Open browser devtools → Network → WS — there should be a long-lived `cable` connection.
- **`gh pr create` fails with "no upstream".** The `git push -u` in PrCreator should set it; if not, inspect the worktree's `.git` config.
- **Node subprocess can't find the SDK.** Ensure `npm install` was run at the repo root, and that the Rails job's working directory is the repo root (which it is by default).
- **Runaway agent eating credits.** The 15-minute timeout in AgentRunner caps it. Lower `AgentRunner::DEFAULT_TIMEOUT` if you want tighter budgets during testing.
