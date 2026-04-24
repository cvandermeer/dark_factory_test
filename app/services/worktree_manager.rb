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
