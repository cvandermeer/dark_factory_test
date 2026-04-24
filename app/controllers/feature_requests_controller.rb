class FeatureRequestsController < ApplicationController
  def index
    @feature_requests = FeatureRequest.order(created_at: :desc)
    @feature_request = FeatureRequest.new
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

  private

  def feature_request_params
    params.require(:feature_request).permit(:title, :body)
  end
end
