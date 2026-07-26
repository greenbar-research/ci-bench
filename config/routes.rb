Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  resource :session, only: %i[new create destroy]
  resources :projects, only: %i[index show create] do
    resources :builds, only: :create do
      resources :artifacts, only: :create
      resources :test_cases, only: :create
    end
  end
  root "projects#index"
end
