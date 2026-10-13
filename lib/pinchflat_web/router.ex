defmodule PinchflatWeb.Router do
  use PinchflatWeb, :router
  import PinchflatWeb.Plugs
  import Phoenix.LiveDashboard.Router

  # IMPORTANT: `strip_trailing_extension` in endpoint.ex removes
  # the extension from the path
  pipeline :browser do
    plug :basic_auth
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PinchflatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Shared response-header pipeline for the public per-source feed endpoints (RSS, cover
  # images, media streams). It strips `x-frame-options` and adds CORS plus the baseline
  # security headers the `:browser` pipeline's `put_secure_browser_headers` would otherwise
  # supply, so the responses are embeddable in podcast directories' iframes. No `:accepts`
  # plug here: these controllers send raw responses, and podcast readers send varied Accept
  # headers that content negotiation could reject.
  pipeline :feed do
    plug :allow_iframe_embed
  end

  # OPML-only access-key scope. `token_protected_route` requires the installation's
  # `route_token` query param (constant-time compare) regardless of basic auth, so the full
  # source list is never enumerable without the token. The token deliberately does NOT gate
  # the per-source feed/image/stream routes below (see the `:feed` scope).
  scope "/", PinchflatWeb do
    pipe_through [:maybe_basic_auth, :token_protected_route]

    # has to match before /sources/:id
    get "/sources/opml", Podcasts.PodcastController, :opml_feed
  end

  # Per-source feed scope, gated only by `maybe_basic_auth`. These routes are anonymously
  # reachable when `expose_feed_endpoints` is true (podcast clients fetch enclosure/artwork
  # URLs independently of the feed and cannot carry a query-param token). When it is false
  # they require basic auth only if credentials are configured, and stay anonymous when no
  # credentials are set. They intentionally do not take `route_token`.
  scope "/", PinchflatWeb do
    pipe_through [:maybe_basic_auth, :feed]

    get "/sources/:uuid/feed", Podcasts.PodcastController, :rss_feed
    get "/sources/:uuid/feed_image", Podcasts.PodcastController, :feed_image
    get "/media/:uuid/episode_image", Podcasts.PodcastController, :episode_image

    get "/media/:uuid/stream", MediaItems.MediaItemController, :stream
  end

  scope "/", PinchflatWeb do
    pipe_through :browser

    get "/", Pages.PageController, :home

    resources "/media_profiles", MediaProfiles.MediaProfileController
    resources "/search", Searches.SearchController, only: [:show], singleton: true

    resources "/settings", Settings.SettingController, only: [:show, :update], singleton: true
    get "/settings/cookies", Settings.SettingController, :download_cookies
    get "/download_logs", Settings.SettingController, :download_logs

    get "/diagnostics", Settings.DiagnosticsController, :show
    post "/diagnostics/reset_retryable_jobs", Settings.DiagnosticsController, :reset_retryable_jobs
    post "/diagnostics/reset_job/:id", Settings.DiagnosticsController, :reset_job
    post "/diagnostics/requeue_job/:id", Settings.DiagnosticsController, :requeue_job
    post "/diagnostics/delete_job/:id", Settings.DiagnosticsController, :delete_job

    resources "/sources", Sources.SourceController do
      post "/force_download_pending", Sources.SourceController, :force_download_pending
      post "/force_redownload", Sources.SourceController, :force_redownload
      post "/force_index", Sources.SourceController, :force_index
      post "/force_metadata_refresh", Sources.SourceController, :force_metadata_refresh
      post "/sync_files_on_disk", Sources.SourceController, :sync_files_on_disk

      resources "/media", MediaItems.MediaItemController, only: [:show, :edit, :update, :delete] do
        post "/force_download", MediaItems.MediaItemController, :force_download
      end
    end
  end

  # No auth or CSRF protection for the health check endpoint
  scope "/", PinchflatWeb do
    pipe_through :api

    get "/healthcheck", HealthController, :check, log: false
  end

  # Enforces Basic auth on the dev LiveDashboard even when no credentials are
  # configured: `basic_auth` (in `:browser`) is a no-op on a default install where
  # no credentials are set, so without this the dashboard would be anonymously
  # reachable. `dev_dashboard_basic_auth` denies the request when credentials are
  # absent and enforces Basic auth when they are present.
  pipeline :dev_dashboard do
    plug :dev_dashboard_basic_auth
  end

  scope "/dev" do
    pipe_through [:browser, :dev_dashboard]

    live_dashboard "/dashboard",
      metrics: PinchflatWeb.Telemetry,
      ecto_repos: [Pinchflat.Repo]
  end
end
