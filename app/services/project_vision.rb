class ProjectVision
  PATH = Rails.root.join("docs/project_vision.md")

  DEFAULT_TEXT = <<~MARKDOWN
    # Dark Factory Project Vision

    Dark Factory is an experimental Rails application for autonomous software iteration.

    The product should make it practical to let AI agents improve the app while a human supervises the process at a higher level. The app should emphasize:

    - clear visibility into what each agent is doing
    - simple controls to start, stop, and switch between manual and automatic operation
    - small, reversible iterations even when the experiment does not require formal rollback
    - a useful event history that lets a human audit what changed and why
    - local-first automation without depending on pull requests as the primary workflow

    Good autonomous ideas are narrow, concrete, and easy to verify. Prefer improvements that make the factory more observable, controllable, reliable, or easier to understand.
  MARKDOWN

  def self.read
    File.read(PATH)
  rescue Errno::ENOENT
    DEFAULT_TEXT
  end

  def self.write(text)
    FileUtils.mkdir_p(PATH.dirname)
    File.write(PATH, text.to_s)
  end
end
