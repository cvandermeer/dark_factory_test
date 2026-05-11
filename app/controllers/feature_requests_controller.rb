class FeatureRequestsController < ApplicationController
  def index
    @feature_requests = FeatureRequest.order(created_at: :desc)
    @feature_request = FeatureRequest.new
    @factory_setting = FactorySetting.current
  end

  def show
    @feature_request = FeatureRequest.find(params[:id])
    @events = @feature_request.agent_events.in_order
  end

  def create
    @feature_request = FeatureRequest.new(feature_request_params)
    if @feature_request.save
      redirect_to root_path
    else
      @feature_requests = FeatureRequest.order(created_at: :desc)
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    FeatureRequest.find(params[:id]).destroy
    redirect_to root_path
  end

  def stop
    feature_request = FeatureRequest.find(params[:id])
    if feature_request.active?
      feature_request.update!(stop_requested_at: Time.current)
    end

    redirect_back fallback_location: root_path
  end

  def retry
    feature_request = FeatureRequest.find(params[:id])
    unless feature_request.status == "failed"
      return render plain: "Feature request is not in a failed state.", status: :unprocessable_entity
    end

    feature_request.update!(
      status: "todo",
      failure_reason: nil,
      branch_name: nil,
      feedback_addressed: false,
      last_review_seen_at: nil,
      landed_commit_sha: nil,
      review_verdict: nil,
      review_body: nil,
      stop_requested_at: nil
    )
    DarkFactoryJob.perform_later(feature_request.id)

    redirect_to feature_request, notice: "Feature request has been re-queued."
  end

  private

  def feature_request_params
    params.require(:feature_request).permit(:title, :body)
  end
end
