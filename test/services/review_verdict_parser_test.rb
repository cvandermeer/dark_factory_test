require "test_helper"

class ReviewVerdictParserTest < ActiveSupport::TestCase
  test "parses approved verdict JSON" do
    result = ReviewVerdictParser.parse(
      { verdict: "approved", body: "No issues found." }.to_json
    )

    assert_equal "approved", result.verdict
    assert_equal "No issues found.", result.body
  end

  test "parses JSON embedded in model text" do
    result = ReviewVerdictParser.parse(
      "Here is the review:\n{\"verdict\":\"changes_requested\",\"body\":\"Add coverage.\"}"
    )

    assert_equal "changes_requested", result.verdict
    assert_equal "Add coverage.", result.body
  end

  test "parses JSON from inspected SDK result event" do
    result = ReviewVerdictParser.parse(
      "{\"type\"=>\"result\", \"result\"=>\"{\\\"verdict\\\":\\\"changes_requested\\\",\\\"body\\\":\\\"Fix the grouped counts.\\\"}\"}"
    )

    assert_equal "changes_requested", result.verdict
    assert_equal "Fix the grouped counts.", result.body
  end

  test "rejects unknown verdict" do
    error = assert_raises(ReviewVerdictParser::Error) do
      ReviewVerdictParser.parse({ verdict: "maybe", body: "Unclear." }.to_json)
    end

    assert_match "unknown verdict", error.message
  end
end
