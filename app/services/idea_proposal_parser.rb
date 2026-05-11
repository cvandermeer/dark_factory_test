require "base64"

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
    json = extract_json
    data = parse_json(json) || parse_relaxed_json_fields(json)
    title = decoded_value(data, "title").to_s.strip
    body = decoded_value(data, "body").to_s.strip
    rationale = decoded_value(data, "rationale").to_s.strip

    raise Error, "title is blank" if title.blank?
    raise Error, "body is blank" if body.blank?

    Proposal.new(title:, body:, rationale:)
  rescue KeyError => e
    raise Error, e.message
  end

  private

  def parse_json(json)
    JSON.parse(json)
  rescue JSON::ParserError
    nil
  end

  def parse_relaxed_json_fields(json)
    fields = {
      "title" => extract_relaxed_field(json, "title", "body"),
      "body" => extract_relaxed_field(json, "body", "rationale"),
      "rationale" => extract_relaxed_field(json, "rationale", nil)
    }.compact

    raise Error, "could not parse idea proposal JSON" unless fields.key?("title") && fields.key?("body")

    fields
  end

  def extract_relaxed_field(json, key, next_key)
    pattern =
      if next_key
        /"#{Regexp.escape(key)}"\s*:\s*"(.*)"\s*,\s*"#{Regexp.escape(next_key)}"\s*:/m
      else
        /"#{Regexp.escape(key)}"\s*:\s*"(.*)"\s*\}\s*$/m
      end

    value = json.match(pattern)&.captures&.first
    relaxed_unescape(value) if value
  end

  def relaxed_unescape(value)
    value
      .gsub("\\r\\n", "\n")
      .gsub("\\n", "\n")
      .gsub("\\t", "\t")
      .gsub('\"', '"')
      .gsub("\\\\", "\\")
  end

  def decoded_value(data, key)
    encoded = data["#{key}_base64"]
    return Base64.strict_decode64(encoded).force_encoding("UTF-8") if encoded.present?

    data.fetch(key, "")
  rescue ArgumentError => e
    raise Error, "#{key}_base64 is invalid: #{e.message}"
  end

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
