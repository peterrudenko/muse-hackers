defmodule Api.Router do
  @moduledoc false

  use Api, :router
  require Ueberauth

  pipeline :api do
    plug :accepts, [:v1]
    plug Api.Plugs.APIVersion
    plug Api.Plugs.CamelCaseDecoder
  end

  pipeline :clients do
    plug Api.Auth.CheckClient
  end

  pipeline :authenticated do
    plug Api.Auth.CheckToken
  end

  scope "/", Api, as: :api do
    pipe_through :api

    # username/password registration and login;
    # I wonder if the only available way to sign up should be via Github
    if Mix.env == :test do
      post "/join", RegistrationController, :sign_up, as: :signup
      post "/login", SessionController, :sign_in, as: :login
    end

    # some stuff for specific client apps
    # e.g. `/api/v1/clients/helio/translations`
    scope "/clients", as: :client do
      pipe_through :clients
      get "/:app/info", ClientAppController, :get_client_info, as: :app_info
      get "/:app/:resource", ClientAppResourceController, :get_client_resource, as: :resource

      # initialize web authentication via, say, Github:
      # creates a new Clients.AuthSession and returns its id, secret key and browser url
      post "/:app/auth", AuthSessionController, :init_client_auth_session, as: :auth_init

      # requires auth id and secret key received using a method above,
      # returns 404, if auth with such id and key does not exist
      # returns 204, if auth is still in progress and there is no token available,
      # returns 410, if auth was completed with an error (or is stale), then deletes auth request 
      # returns 200 with token, if auth completed successfully, then deletes the auth request
      post "/:app/auth/check", AuthSessionController, :finalise_client_auth_session, as: :auth_finalise

      pipe_through :authenticated
      post "/:app/:resource/update", ClientAppResourceController, :update_client_resource, as: :resource_update
      post "/", ClientAppController, :create_or_update, as: :app
      get "/", ClientAppController, :index, as: :app
    end

    # restrict unauthenticated access for routes below
    pipe_through :authenticated

    # returns the logged in user's profile, including all active sessions
    # and the summary of available resources (similar to client app info);
    # note that user's project are not returned here, instead use get /vcs/projects
    get "/me", UserController, :get_current_user, as: :user

    # e.g. /my/arpeggiators/arp-name or /my/scripts/script-name
    # client app work as follows:
    # - receive a user profile containing resource hashes and update time millis
    # - check for local user's resource timestamps
    get "/my/:resource_type/:resource_name", UserResourceController, :get_user_resource, as: :user_resource
    put "/my/:resource_type/:resource_name", UserResourceController, :update_user_resource, as: :user_resource

    # some users admin endpoints
    resources "/users", UserController, only: [:index, :delete], as: :user

    # this endpoint provides a kind of a sliding session:
    # first, it checks for a token, that is
    #   1) valid and unexpired,
    #   2) present in active_sessions for a given device id;
    # if passed, it issues a new token and saves it in the related active session
    # (there can be only one session per user and device id),
    # so that if user runs the app, say, at least once a week, his session won't expire
    # (and if the token is compromised/stolen, the user's session won't be prolonged,
    # eventually forcing him to re-login, and thus invalidating attacker's session);
    # and, although re-issuing a token is stateful, authentication is still stateless and fast
    post "/reauth", SessionController, :refresh_token, as: :relogin

    # a simple authentication check (mainly used in tests)
    get "/session-status", SessionController, :is_authenticated, as: :session_status

    # version control stuff
    scope "/vcs", as: :vcs do
      scope "/projects" do
        get "/", ProjectController, :index
        get "/:id", ProjectController, :summary
        get "/:id/heads", ProjectController, :heads
        put "/:id", ProjectController, :create_or_update
      end

      scope "/revisions" do
        get "/:id", RevisionController, :show
        put "/:id", RevisionController, :create
      end
    end
  end
end
