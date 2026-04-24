class AgentEvent < ApplicationRecord
  KINDS = %w[text tool_use tool_result system error].freeze

  belongs_to :feature_request

  validates :kind, inclusion: { in: KINDS }
  validates :sequence, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :in_order, -> { order(:sequence) }
end
