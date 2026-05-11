class FeatureRequest < ApplicationRecord
  STATUSES = %w[todo doing reviewing addressing_feedback landing done stopped failed].freeze
  SOURCES = %w[manual automatic].freeze

  has_many :agent_events, -> { order(:sequence) }, dependent: :destroy

  validates :title, presence: true, length: { maximum: 200 }
  validates :body, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }

  after_create_commit  -> { broadcast_prepend_to "board", target: "fr-column-#{status}", partial: "feature_requests/card", locals: { feature_request: self } }
  after_update_commit  :broadcast_card_refresh
  after_destroy_commit -> { broadcast_remove_to "board" }

  scope :todo,             -> { where(status: "todo") }
  scope :doing,            -> { where(status: "doing") }
  scope :reviewing,        -> { where(status: "reviewing") }
  scope :addressing_feedback, -> { where(status: "addressing_feedback") }
  scope :landing,          -> { where(status: "landing") }
  scope :done,             -> { where(status: "done") }
  scope :stopped,          -> { where(status: "stopped") }
  scope :failed,           -> { where(status: "failed") }

  def active?
    %w[todo doing reviewing addressing_feedback landing].include?(status)
  end

  def stop_requested?
    stop_requested_at.present?
  end

  def slug
    title.parameterize.presence || "untitled"
  end

  def branch
    branch_name || "feature-request/#{id}-#{slug}"
  end

  after_create_commit :enqueue_dark_factory_job, if: -> { status == "todo" }

  private

  def enqueue_dark_factory_job
    DarkFactoryJob.perform_later(id)
  end

  def broadcast_card_refresh
    if saved_change_to_status?
      broadcast_remove_to "board"
      broadcast_prepend_to "board", target: "fr-column-#{status}", partial: "feature_requests/card", locals: { feature_request: self }
    else
      broadcast_replace_to "board", partial: "feature_requests/card", locals: { feature_request: self }
    end

    broadcast_replace_to(
      "feature_request_#{id}",
      target: ActionView::RecordIdentifier.dom_id(self, :header),
      partial: "feature_requests/header",
      locals: { feature_request: self }
    )
  end
end
