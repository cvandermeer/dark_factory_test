class FactorySetting < ApplicationRecord
  MODES = %w[manual automatic].freeze

  validates :mode, inclusion: { in: MODES }

  def self.current
    first_or_create!(mode: "manual")
  end

  def self.automatic?
    current.mode == "automatic"
  end

  def automatic?
    mode == "automatic"
  end

  def manual?
    mode == "manual"
  end
end
