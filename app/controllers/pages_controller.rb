class PagesController < ApplicationController
  BOTS = [
    {
      name: "Implementation Agent",
      icon: "🏗️",
      color_class: "stats-bot--implement",
      description: "The builder. It reads your feature request, explores the codebase to understand how it works, writes or edits the files it needs to change, and commits the result. When it is done it pushes the branch and opens a pull request on GitHub."
    },
    {
      name: "Review Agent",
      icon: "🔍",
      color_class: "stats-bot--review",
      description: "The quality checker. It reads the pull request diff, compares it against your original description, and posts a formal GitHub review: either an approval or a list of requested changes with specific comments."
    },
    {
      name: "Feedback Agent",
      icon: "🛠️",
      color_class: "stats-bot--address",
      description: "The fixer. When the Review Agent asks for changes, this agent reads every comment, makes the necessary edits, commits them, and pushes to the same PR branch so the review can be re-evaluated."
    }
  ].freeze

  def info
  end

  def faq
  end

  def refund
  end

  def stats
    @total       = FeatureRequest.count
    @by_status   = FeatureRequest::STATUSES.index_with { |s| FeatureRequest.where(status: s).count }
    @merged      = FeatureRequest.where.not(pr_merged_at: nil).count
    @bots        = BOTS
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
