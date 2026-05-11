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

  test "parses base64 encoded proposal JSON" do
    proposal = IdeaProposalParser.parse({
      title_base64: Base64.strict_encode64("Add a Power Attack move"),
      body_base64: Base64.strict_encode64("Add a move named \"Power Attack\" to /game battles."),
      rationale_base64: Base64.strict_encode64("Quotes stay inside base64.")
    }.to_json)

    assert_equal "Add a Power Attack move", proposal.title
    assert_equal "Add a move named \"Power Attack\" to /game battles.", proposal.body
    assert_equal "Quotes stay inside base64.", proposal.rationale
  end

  test "recovers proposal fields when body contains unescaped quotes" do
    proposal = IdeaProposalParser.parse(
      "{\"title\":\"Add a warrior move\",\"body\":\"Add a move named \"Power Attack\" to the /game battle screen.\",\"rationale\":\"Expands combat.\"}"
    )

    assert_equal "Add a warrior move", proposal.title
    assert_equal "Add a move named \"Power Attack\" to the /game battle screen.", proposal.body
    assert_equal "Expands combat.", proposal.rationale
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
