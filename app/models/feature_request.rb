class FeatureRequest < ApplicationRecord
  STATUSES = %w[todo doing to_review failed].freeze

  has_many :agent_events, -> { order(:sequence) }, dependent: :destroy

  validates :title, presence: true, length: { maximum: 200 }
  validates :body, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :todo,      -> { where(status: "todo") }
  scope :doing,     -> { where(status: "doing") }
  scope :to_review, -> { where(status: "to_review") }
  scope :failed,    -> { where(status: "failed") }

  def slug
    title.parameterize.presence || "untitled"
  end

  def branch
    branch_name || "feature-request/#{id}-#{slug}"
  end

  after_create_commit :enqueue_dark_factory_job

  private

  def enqueue_dark_factory_job
    DarkFactoryJob.perform_later(id)
  end
end
