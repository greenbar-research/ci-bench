Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  resources :projects, only: %i[index create]
  root "projects#index"
end
