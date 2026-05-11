require "test_helper"

class IdeaProposalParserTest < ActiveSupport::TestCase
  test "parses proposal JSON" do
    proposal = IdeaProposalParser.parse(
      { title: "Add mode status", body: "Show mode on the board.", rationale: "Improves visibility." }.to_json
    )

    assert_equal "Add mode status", proposal.title
    assert_equal "Show mode on the board.", proposal.body
    assert_equal "Improves visibility.", proposal.rationale
  end

  test "rejects blank body" do
    error = assert_raises(IdeaProposalParser::Error) do
      IdeaProposalParser.parse({ title: "Incomplete", body: "" }.to_json)
    end

    assert_match "body is blank", error.message
  end

  test "parses JSON embedded in SDK result text" do
    proposal = IdeaProposalParser.parse(
      "{\"type\"=>\"result\", \"result\"=>\"{\\\"title\\\":\\\"Improve jobs page\\\",\\\"body\\\":\\\"Show finished idea jobs.\\\",\\\"rationale\\\":\\\"Debuggability.\\\"}\"}"
    )

    assert_equal "Improve jobs page", proposal.title
    assert_equal "Show finished idea jobs.", proposal.body
  end

  test "idea runner prefers final result over partial assistant text" do
    stdout = [
      { raw: { type: "assistant", message: { content: [{ type: "text", text: "{\"title\":\"Show" }] } } }.to_json,
      { raw: { type: "result", result: { title: "Show queue health", body: "Add queue health to the board.", rationale: "Improves observability." }.to_json } }.to_json
    ].join("\n")

    runner = IdeaAgentRunner.new(vision: "", recent_requests: "")
    assert_equal(
      "{\"title\":\"Show queue health\",\"body\":\"Add queue health to the board.\",\"rationale\":\"Improves observability.\"}",
      runner.send(:extract_assistant_text, stdout)
    )
  end
end
