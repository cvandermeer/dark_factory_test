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
