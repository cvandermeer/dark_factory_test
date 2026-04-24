Rails.application.routes.draw do
  root "feature_requests#index"
  resources :feature_requests, only: [:index, :show, :create, :destroy]

  get "up" => "rails/health#show", as: :rails_health_check
end
