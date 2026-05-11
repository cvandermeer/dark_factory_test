class JobsController < ApplicationController
  def index
    @ready_executions = SolidQueue::ReadyExecution.includes(:job).order(:priority, :job_id).limit(50)
    @claimed_executions = SolidQueue::ClaimedExecution.includes(:job, :process).order(created_at: :desc).limit(50)
    @scheduled_executions = SolidQueue::ScheduledExecution.includes(:job).order(:scheduled_at, :priority).limit(50)
    @failed_executions = SolidQueue::FailedExecution.includes(:job).order(created_at: :desc).limit(20)
    @processes = SolidQueue::Process.order(last_heartbeat_at: :desc).limit(20)
  end
end
