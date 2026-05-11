class IdeaProposalParser
  class Error < StandardError; end

  Proposal = Data.define(:title, :body, :rationale)

  def self.parse(text)
    new(text).parse
  end

  def initialize(text)
    @text = text.to_s.strip
  end

  def parse
    data = JSON.parse(extract_json)
    title = data.fetch("title").to_s.strip
    body = data.fetch("body").to_s.strip
    rationale = data.fetch("rationale", "").to_s.strip

    raise Error, "title is blank" if title.blank?
    raise Error, "body is blank" if body.blank?

    Proposal.new(title:, body:, rationale:)
  rescue JSON::ParserError, KeyError => e
    raise Error, e.message
  end

  private

  def extract_json
    result = extract_result_string
    return result if result.present?

    return @text if @text.start_with?("{") && @text.end_with?("}")

    match = @text.match(/\{.*\}/m)
    raise Error, "no JSON object found in idea output" unless match

    match[0]
  end

  def extract_result_string
    match = @text.match(/"result"=>("(?:\\.|[^"\\])*")/m)
    return unless match

    JSON.parse(match[1]).to_s.strip
  rescue JSON::ParserError
    nil
  end
end
