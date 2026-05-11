require "test_helper"

class AgentRunnerTest < ActiveSupport::TestCase
  setup do
    @feature_request = feature_requests(:one)
    @runner = AgentRunner.new(feature_request: @feature_request, worktree_path: Rails.root.to_s)
  end

  test "drops assistant messages that only contain tool use blocks" do
    kind, payload = @runner.send(:classify, {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "app.rb" } }
        ]
      }
    })

    assert_nil kind
    assert_nil payload
  end

  test "keeps assistant text blocks" do
    kind, payload = @runner.send(:classify, {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "thinking", "thinking" => "hidden" },
          { "type" => "text", "text" => "I updated the stats page." }
        ]
      }
    })

    assert_equal "text", kind
    assert_equal "I updated the stats page.", payload["content"]
  end

  test "drops user envelope messages" do
    assert_nil @runner.send(:classify, { "type" => "user", "message" => { "content" => [] } })
  end
end
