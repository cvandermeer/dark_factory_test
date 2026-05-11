class FactorySettingsController < ApplicationController
  def update
    setting = FactorySetting.current
    mode = params.require(:factory_setting).fetch(:mode)
    setting.update!(
      mode: mode,
      automatic_started_at: mode == "automatic" ? Time.current : nil
    )

    IdeaGenerationJob.perform_later if setting.automatic?

    redirect_to root_path
  end
end
