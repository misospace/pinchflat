defmodule PinchflatWeb.RouterTest do
  @moduledoc false

  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  setup do
    old_username = Application.get_env(:pinchflat, :basic_auth_username)
    old_password = Application.get_env(:pinchflat, :basic_auth_password)
    old_expose = Application.get_env(:pinchflat, :expose_feed_endpoints)

    on_exit(fn ->
      Application.put_env(:pinchflat, :basic_auth_username, old_username)
      Application.put_env(:pinchflat, :basic_auth_password, old_password)
      Application.put_env(:pinchflat, :expose_feed_endpoints, old_expose)
    end)

    :ok
  end

  # Locks the public-feed authorization contract: `route_token` gates only the OPML source
  # list; the per-source feed/image/stream routes are gated solely by `maybe_basic_auth`.
  describe "public feed authorization with basic auth configured" do
    setup do
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")
      Application.put_env(:pinchflat, :expose_feed_endpoints, false)
      :ok
    end

    test "OPML requires both basic auth and the route token", %{conn: conn} do
      token = Settings.get!(:route_token)

      assert get(conn, ~p"/sources/opml.xml").status == 401
      assert get(conn, ~p"/sources/opml.xml?#{[route_token: token]}").status == 401
      assert get_with_auth(conn, ~p"/sources/opml.xml").status == 401
      assert get_with_auth(conn, ~p"/sources/opml.xml?#{[route_token: token]}").status == 200
    end

    test "feed endpoints require basic auth when exposure is off", %{conn: conn} do
      source = source_fixture()

      assert get(conn, ~p"/sources/#{source.uuid}/feed").status == 401
      assert get_with_auth(conn, ~p"/sources/#{source.uuid}/feed").status == 200
    end

    test "feed endpoints ignore the route token entirely", %{conn: conn} do
      source = source_fixture()
      token = Settings.get!(:route_token)

      assert get(conn, ~p"/sources/#{source.uuid}/feed?#{[route_token: token]}").status == 401
    end
  end

  describe "public feed authorization with expose_feed_endpoints enabled" do
    setup do
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")
      Application.put_env(:pinchflat, :expose_feed_endpoints, true)
      :ok
    end

    test "OPML still requires the route token", %{conn: conn} do
      token = Settings.get!(:route_token)

      assert get(conn, ~p"/sources/opml.xml").status == 401
      assert get(conn, ~p"/sources/opml.xml?#{[route_token: "incorrect"]}").status == 401
      assert get(conn, ~p"/sources/opml.xml?#{[route_token: token]}").status == 200
    end

    test "feed endpoint is reachable without a token or basic auth", %{conn: conn} do
      source = source_fixture()

      assert get(conn, ~p"/sources/#{source.uuid}/feed").status == 200
    end

    test "feed_image is reachable without a token or basic auth", %{conn: conn} do
      source = source_with_metadata_attachments()

      assert get(conn, ~p"/sources/#{source.uuid}/feed_image").status == 200
    end

    test "episode_image is reachable without a token or basic auth", %{conn: conn} do
      media_item = media_item_with_attachments()

      assert get(conn, ~p"/media/#{media_item.uuid}/episode_image").status == 200
    end

    test "media stream is reachable without a token or basic auth", %{conn: conn} do
      media_item = media_item_with_attachments()

      assert get(conn, ~p"/media/#{media_item.uuid}/stream").status == 200
    end

    test "an unknown source still 404s, proving dispatch reached the controller", %{conn: conn} do
      conn = get(conn, ~p"/sources/00000000-0000-0000-0000-000000000000/feed")

      assert conn.status == 404
      assert conn.resp_body == "Source not found"
    end
  end

  describe "public feed authorization with no credentials configured" do
    setup do
      Application.put_env(:pinchflat, :basic_auth_username, nil)
      Application.put_env(:pinchflat, :basic_auth_password, nil)
      Application.put_env(:pinchflat, :expose_feed_endpoints, false)
      :ok
    end

    test "OPML still requires the route token", %{conn: conn} do
      token = Settings.get!(:route_token)

      assert get(conn, ~p"/sources/opml.xml").status == 401
      assert get(conn, ~p"/sources/opml.xml?#{[route_token: token]}").status == 200
    end

    test "feed endpoints are anonymous even though exposure is off", %{conn: conn} do
      source = source_fixture()

      assert get(conn, ~p"/sources/#{source.uuid}/feed").status == 200
    end
  end

  defp get_with_auth(conn, path) do
    conn
    |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("user", "pass"))
    |> get(path)
  end
end
