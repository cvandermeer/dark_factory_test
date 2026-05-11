class ReviewVerdictParser
  class Error < StandardError; end

  VERDICTS = %w[approved changes_requested].freeze

  Result = Data.define(:verdict, :body)

  def self.parse(text)
    new(text).parse
  end

  def initialize(text)
    @text = text.to_s.strip
  end

  def parse
    data = JSON.parse(extract_json)
    verdict = data.fetch("verdict").to_s
    body = data.fetch("body").to_s.strip

    raise Error, "unknown verdict: #{verdict.inspect}" unless VERDICTS.include?(verdict)
    raise Error, "review body is blank" if body.blank?

    Result.new(verdict:, body:)
  rescue JSON::ParserError, KeyError => e
    raise Error, e.message
  end

  private

  def extract_json
    result = extract_result_string
    return result if result.present?

    return @text if @text.start_with?("{") && @text.end_with?("}")

    match = @text.match(/\{.*\}/m)
    raise Error, "no JSON object found in reviewer output" unless match

    match[0]
  end

  def extract_result_string
    match = @text.match(/"result"=>("(?:\\.|[^"\\])*")/m)
    return unless match

    result = JSON.parse(match[1])
    result.to_s.strip
  rescue JSON::ParserError
    nil
  end
end
