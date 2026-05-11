class PagesController < ApplicationController
  def info
  end

  def faq
  end

  def stats
    @total = FeatureRequest.count
    counts = FeatureRequest.group(:status).count
    @by_status = FeatureRequest::STATUSES.index_with { |status| counts.fetch(status, 0) }
    @done = @by_status.fetch("done", 0)
    @failed = @by_status.fetch("failed", 0)
    @stopped = @by_status.fetch("stopped", 0)
    @automatic = FeatureRequest.where(source: "automatic").count
    @success_rate = @total.positive? ? (@done.to_f / @total * 100).round(1) : nil

    @total_events = AgentEvent.count
    @tool_calls = AgentEvent.where(kind: "tool_use").count
    @errors = AgentEvent.where(kind: "error").count
  end

  def refund
  end

  def submit_refund
    @email  = params[:email].to_s.strip
    @reason = params[:reason].to_s.strip

    if @email.blank? || @reason.blank?
      flash.now[:alert] = "Please fill in all fields."
      render :refund, status: :unprocessable_entity
    else
      flash[:notice] = "Your refund request has been received. We'll be in touch at #{@email} within 2 business days."
      redirect_to faq_path
    end
  end
end
