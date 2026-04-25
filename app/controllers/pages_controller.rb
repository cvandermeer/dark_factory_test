class PagesController < ApplicationController
  def faq
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
