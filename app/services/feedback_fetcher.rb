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
