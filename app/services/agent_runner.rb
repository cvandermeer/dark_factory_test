class AgentRunner
  class AgentFailed < StandardError; end
  class Timeout < StandardError; end
  class Stopped < StandardError; end

  DEFAULT_TIMEOUT = 15 * 60 # seconds

  # mode: :implement (default), :reviewer, or :address
  # stdin_payload: the hash that gets JSON-encoded and piped to the Node subprocess.
  #   - implement: { title:, body: }
  #   - reviewer:  { title:, body: }
  #   - address:   { title:, body:, diff:, feedback: }
  def initialize(feature_request:, worktree_path:, mode: :implement, stdin_payload: nil, timeout: DEFAULT_TIMEOUT)
    @fr = feature_request
    @worktree = worktree_path
    @mode = mode
    @stdin_payload = stdin_payload || { title: @fr.title, body: @fr.body }
    @timeout = timeout
    @sequence = @fr.agent_events.maximum(:sequence).to_i + 1
    @task_progress_count = 0
    @compacted_events = 0
  end

  def run!
    cmd = ["node", Rails.root.join("script/run_agent.mjs").to_s,
           "--worktree", @worktree, "--mode", @mode.to_s]
    env = { "ANTHROPIC_API_KEY" => ENV["ANTHROPIC_API_KEY"] }

    Rails.logger.info("[AgentRunner mode=#{@mode}] spawning: #{cmd.join(' ')}")
    stderr_buf = +""
    exit_status = nil
    stopped = false

    Open3.popen3(env, *cmd, chdir: Rails.root.to_s) do |stdin, stdout, stderr, wait_thr|
      stdin.write(JSON.dump(@stdin_payload))
      stdin.close

      err_reader = Thread.new { stderr.each_line { |l| stderr_buf << l } }
      stop_reader = Thread.new do
        loop do
          break unless wait_thr.alive?
          if @fr.reload.stop_requested?
            stopped = true
            Process.kill("TERM", wait_thr.pid)
            break
          end
          sleep 1
        end
      rescue ActiveRecord::RecordNotFound
        stopped = true
        Process.kill("TERM", wait_thr.pid) if wait_thr.alive?
      rescue Errno::ESRCH
      end

      started = Time.now
      stdout.each_line do |line|
        raise Timeout if Time.now - started > @timeout
        handle_line(line)
      end

      err_reader.join(2)
      stop_reader.kill
      exit_status = wait_thr.value.exitstatus
    end

    raise Stopped, "stopped_by_user" if stopped

    if exit_status != 0
      last_error = @fr.agent_events.where(kind: "error").order(:sequence).last&.payload&.dig("message")
      tail = stderr_buf.lines.last(40).join
      detail = last_error.presence || tail.presence || "(no output)"
      raise AgentFailed, "agent_exited: #{exit_status} — #{detail}"
    end

    append_compaction_summary
  end

  private

  def handle_line(line)
    raw = JSON.parse(line)
    kind, payload = classify(raw["raw"] || raw)
    unless kind
      @compacted_events += 1
      return
    end

    append_event(kind, payload)
  rescue JSON::ParserError
    Rails.logger.warn("[AgentRunner] non-JSON stdout: #{line.inspect}")
  end

  def append_event(kind, payload)
    event = @fr.agent_events.create!(kind: kind, payload: payload, sequence: @sequence)
    @sequence += 1
    broadcast(event)
  end

  def append_compaction_summary
    return if @compacted_events.zero?

    append_event("system", { "message" => "compacted #{@compacted_events} low-detail agent events (#{@mode})" })
  end

  def classify(msg)
    case msg["type"]
    when "assistant", "text"
      content = extract_text(msg)
      return if content.blank?

      ["text", { "content" => content }]
    when "result"
      if msg["result"].present?
        ["text", { "content" => msg["result"].to_s }]
      else
        nil
      end
    when "system"
      classify_system(msg)
    when "user"
      nil
    when "tool_use"
      ["tool_use", { "tool" => msg["name"], "args" => msg["input"] }]
    when "tool_result"
      ["tool_result", { "tool" => msg["name"], "output" => stringify_output(msg["content"]) }]
    when "error"
      ["error", { "message" => msg.dig("error", "message") || msg["message"].to_s }]
    when "done"
      ["system", { "message" => "agent finished (#{@mode})" }]
    else
      nil
    end
  end

  def extract_text(msg)
    content = msg.dig("message", "content") || msg["content"] || msg["text"]
    return content if content.is_a?(String)
    return extract_content_blocks(content) if content.is_a?(Array)

    nil
  end

  def extract_content_blocks(content)
    content.filter_map do |block|
      next block unless block.is_a?(Hash)
      next block["text"].to_s if block["type"] == "text" && block["text"].present?

      nil
    end.join
  end

  def classify_system(msg)
    case msg["subtype"]
    when "init"
      ["system", { "message" => "agent started (#{@mode})" }]
    when "task_started"
      ["system", { "message" => "task started: #{msg["description"]}" }]
    when "task_completed"
      ["system", { "message" => "task completed: #{msg["description"]}" }]
    when "task_progress"
      @task_progress_count += 1
      return nil unless (@task_progress_count % 10).zero?

      ["system", { "message" => "progress: #{msg["description"]}" }]
    else
      nil
    end
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
