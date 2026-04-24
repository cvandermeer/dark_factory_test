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
