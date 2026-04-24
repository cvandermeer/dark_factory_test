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

  # Best-effort mapping from SDK message shapes to our event kinds.
  # Whatever we don't recognize, we store as "system" with the raw payload.
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
