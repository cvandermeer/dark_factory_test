Rails.application.routes.draw do
  root "feature_requests#index"
  resources :feature_requests, only: [:index, :show, :create, :destroy] do
    post :stop, on: :member
  end
  resource :factory_setting, only: [:update]
  resource :project_vision, only: [:show, :update]

  get "info"   => "pages#info",   as: :info
  get "faq" => "pages#faq", as: :faq
  get "stats" => "pages#stats", as: :stats
  get  "refund" => "pages#refund",        as: :refund
  post "refund" => "pages#submit_refund", as: :submit_refund

  get "up" => "rails/health#show", as: :rails_health_check
end
