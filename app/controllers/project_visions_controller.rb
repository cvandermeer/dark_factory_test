class ProjectVisionsController < ApplicationController
  def show
    @vision = ProjectVision.read
  end

  def update
    vision = params.require(:project_vision).fetch(:body).to_s
    if vision.blank?
      flash.now[:alert] = "Project vision cannot be blank."
      @vision = vision
      render :show, status: :unprocessable_entity
    else
      ProjectVision.write(vision)
      redirect_to project_vision_path, notice: "Project vision updated."
    end
  end
end
