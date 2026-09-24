# frozen_string_literal: true

Rails.application.routes.draw do
  root "overview#index"
  patch "settings", to: "overview#update", as: :settings
  post "check_connection", to: "overview#check_connection"
  get "downloads/:id", to: "overview#download", as: :blob_download

  scope "auth", controller: :auth, as: :auth do
    get "/", action: :index
    post "token"
    post "certificate"
    post "refresh"
    post "manual"
    post "sessions", action: :list_sessions
    post "revoke/:reference", action: :revoke, as: :revoke
    delete "/", action: :logout, as: :logout
  end

  resources :invoices, only: %i[index new create], param: :ksef_number do
    collection do
      post :preview
      post :metadata
      post :fetch
      get "download/:ksef_number", action: :download, as: :download
    end
  end

  get "qr", to: "qr#index"
  post "qr/online", to: "qr#online", as: :qr_online
  post "qr/offline", to: "qr#offline", as: :qr_offline

  resources :sessions, only: %i[index show], param: :reference do
    get "upo/:invoice", action: :invoice_upo, as: :invoice_upo, on: :member
    get "session_upo/:upo", action: :session_upo, as: :upo, on: :member
  end

  get "batch", to: "batches#index"
  post "batch", to: "batches#create"

  scope "exports", controller: :exports, as: :exports do
    get "/", action: :index
    post "/", action: :create
    post "sync"
  end

  scope "tokens", controller: :tokens, as: :tokens do
    get "/", action: :index
    post "/", action: :create
    post "list"
    post "status"
    post "revoke/:reference", action: :revoke, as: :revoke
  end

  scope "certificates", controller: :certificates, as: :certificates do
    get "/", action: :index
    post "limits"
    post "enrollment_data"
    post "enroll"
    post "enrollment_status"
    post "list"
    post "retrieve"
    post "revoke"
  end

  scope "permissions", controller: :permissions, as: :permissions do
    get "/", action: :index
    post "query"
    post "grant"
    post "operation"
    post "revoke"
  end

  get "limits", to: "limits#index"
  post "limits", to: "limits#show", as: :load_limits

  scope "test_data", controller: :test_data, as: :test_data do
    get "/", action: :index
    post "subject"
    post "remove_subject"
    post "person"
    post "permissions"
  end
end
