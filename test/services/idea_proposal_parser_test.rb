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
end
