require "fileutils"
require "securerandom"
require "shellwords"

class MainlineLandinger
  class Error < StandardError; end
  class Stopped < StandardError; end

  DEFAULT_VERIFY_COMMAND = "bin/rails test"

  def initialize(repo_root:, branch:, title:, verify_command: ENV.fetch("DARK_FACTORY_VERIFY_CMD", DEFAULT_VERIFY_COMMAND), stop_requested: -> { false })
    @repo_root = repo_root
    @branch = branch
    @title = title
    @verify_command = verify_command
    @stop_requested = stop_requested
    @lock_path = File.join(repo_root, ".git", "dark_factory_landing.lock")
    @landing_branch = "dark-factory/landing-#{SecureRandom.hex(4)}"
    @landing_path = File.expand_path("../df_work/#{@landing_branch.tr('/', '-')}", repo_root)
  end

  def land!
    File.open(@lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      begin
        check_stop!
        prepare_landing_worktree!
        check_stop!
        squash_merge!
        check_stop!
        verify!
        check_stop!
        commit!
        check_stop!
        push!
        sha = current_sha
        sync_repo_main_if_clean
        sha
      ensure
        teardown_landing_worktree!
      end
    end
  end

  private

  def prepare_landing_worktree!
    FileUtils.mkdir_p(File.dirname(@landing_path))
    run_in_repo!("git", "fetch", "origin", "main")
    run_in_repo!("git", "worktree", "add", "-b", @landing_branch, @landing_path, "origin/main")
  end

  def squash_merge!
    run!("git", "merge", "--squash", @branch, failure_prefix: "landing_failed")
  end

  def verify!
    argv = Shellwords.split(@verify_command)
    raise Error, "verification command is blank" if argv.empty?

    run!(*argv, failure_prefix: "verification_failed")
  end

  def commit!
    run!("git", "commit", "-m", commit_message)
  end

  def push!
    run!("git", "push", "origin", "HEAD:main", failure_prefix: "push_main_failed")
  end

  def current_sha
    run!("git", "rev-parse", "HEAD").strip
  end

  def commit_message
    @title.presence || "Land autonomous agent change"
  end

  def run!(*cmd, failure_prefix: nil)
    out, err, status = Open3.capture3(*cmd, chdir: @landing_path)
    return out if status.success?

    detail = [err, out].join("\n").strip
    prefix = failure_prefix || "#{cmd.first}_failed"
    raise Error, "#{prefix}: #{cmd.join(' ')} exited #{status.exitstatus}\n#{detail}"
  end

  def check_stop!
    raise Stopped, "stopped_by_user" if @stop_requested.call
  end

  def run_in_repo!(*cmd)
    out, err, status = Open3.capture3(*cmd, chdir: @repo_root)
    return out if status.success?

    detail = [err, out].join("\n").strip
    raise Error, "#{cmd.first}_failed: #{cmd.join(' ')} exited #{status.exitstatus}\n#{detail}"
  end

  def teardown_landing_worktree!
    run_in_repo!("git", "worktree", "remove", "--force", @landing_path) if File.directory?(@landing_path)
    run_in_repo!("git", "branch", "-D", @landing_branch)
  rescue Error => e
    Rails.logger.warn("[MainlineLandinger] teardown failed: #{e.message}")
    FileUtils.rm_rf(@landing_path)
  end

  def sync_repo_main_if_clean
    branch = run_in_repo!("git", "branch", "--show-current").strip
    return unless branch == "main"

    status = run_in_repo!("git", "status", "--porcelain").strip
    return if status.present?

    run_in_repo!("git", "fetch", "origin", "main")
    run_in_repo!("git", "pull", "--ff-only", "origin", "main")
  rescue Error => e
    Rails.logger.warn("[MainlineLandinger] local main sync skipped: #{e.message}")
  end
end
