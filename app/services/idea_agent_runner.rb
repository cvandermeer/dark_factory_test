require "timeout"

class IdeaAgentRunner
  class Error < StandardError; end

  DEFAULT_TIMEOUT = 15 * 60

  def initialize(vision:, recent_requests:, timeout: DEFAULT_TIMEOUT)
    @vision = vision
    @recent_requests = recent_requests
    @timeout = timeout
  end

  def run!
    cmd = [
      "node",
      Rails.root.join("script/run_agent.mjs").to_s,
      "--worktree",
      Rails.root.to_s,
      "--mode",
      "idea"
    ]
    env = { "ANTHROPIC_API_KEY" => ENV["ANTHROPIC_API_KEY"] }
    stdin_payload = JSON.dump(vision: @vision, recent_requests: @recent_requests)
    stdout = +""
    stderr = +""
    status = nil

    Timeout.timeout(@timeout) do
      stdout, stderr, status = Open3.capture3(env, *cmd, stdin_data: stdin_payload, chdir: Rails.root.to_s)
    end

    raise Error, "idea_agent_exited: #{status.exitstatus}\n#{stderr.presence || stdout}" unless status.success?

    proposal_text = extract_assistant_text(stdout)
    IdeaProposalParser.parse(proposal_text)
  rescue Timeout::Error
    raise Error, "idea_agent_timeout: #{@timeout} seconds"
  rescue IdeaProposalParser::Error => e
    raise Error, "idea_parse_failed: #{e.message}"
  end

  private

  def extract_assistant_text(stdout)
    texts = stdout.lines.filter_map do |line|
      raw = JSON.parse(line).fetch("raw")
      next unless raw["type"] == "assistant" || raw["type"] == "text"

      extract_text(raw)
    rescue JSON::ParserError, KeyError
      nil
    end

    text = texts.join("\n").strip
    raise Error, "idea_agent_produced_no_text" if text.blank?

    text
  end

  def extract_text(msg)
    content = msg["content"] || msg["text"]
    return content if content.is_a?(String)
    return content.map { |c| c.is_a?(Hash) ? c["text"].to_s : c.to_s }.join if content.is_a?(Array)

    nil
  end
end
