class FeatureRequestsController < ApplicationController
  def index
    @feature_requests = FeatureRequest.order(created_at: :desc)
    @feature_request = FeatureRequest.new
    @factory_setting = FactorySetting.current
    @idea_job_status = idea_job_status
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

    if automatic_idea_failure?(feature_request)
      IdeaGenerationJob.perform_later
      return redirect_to root_path, notice: "Automatic idea generation has been re-queued."
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

  def automatic_idea_failure?(feature_request)
    feature_request.source == "automatic" &&
      feature_request.title == "Automatic idea generation failed" &&
      feature_request.failure_reason.to_s.start_with?("idea_")
  end

  def idea_job_status
    if (execution = SolidQueue::ClaimedExecution.includes(:job).where(solid_queue_jobs: { class_name: "IdeaGenerationJob" }).order(created_at: :desc).first)
      return { state: "running", job: execution.job, timestamp: execution.created_at }
    end

    if (execution = SolidQueue::ReadyExecution.includes(:job).where(solid_queue_jobs: { class_name: "IdeaGenerationJob" }).order(:priority, :job_id).first)
      return { state: "queued", job: execution.job, timestamp: execution.job.created_at }
    end

    if (execution = SolidQueue::ScheduledExecution.includes(:job).where(solid_queue_jobs: { class_name: "IdeaGenerationJob" }).order(:scheduled_at, :priority).first)
      return { state: "scheduled", job: execution.job, timestamp: execution.scheduled_at }
    end

    if (execution = SolidQueue::FailedExecution.includes(:job).where(solid_queue_jobs: { class_name: "IdeaGenerationJob" }).order(created_at: :desc).first)
      return { state: "failed", job: execution.job, timestamp: execution.created_at }
    end

    { state: "idle" }
  end
end
