defmodule PinchflatWeb.PodcastControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  describe "opml_feed" do
    test "renders the XML document", %{conn: conn} do
      source = source_fixture()
      route_token = Settings.get!(:route_token)

      conn = get(conn, ~p"/sources/opml.xml?#{[route_token: route_token]}")

      assert conn.status == 200
      assert {"content-type", "application/opml+xml; charset=utf-8"} in conn.resp_headers
      assert {"content-disposition", "inline"} in conn.resp_headers
      assert conn.resp_body =~ ~s"http://www.example.com/sources/#{source.uuid}/feed.xml"
      assert conn.resp_body =~ "text=\"#{source.custom_name}\""
    end

    test "returns 401 if the route token is incorrect", %{conn: conn} do
      conn = get(conn, ~p"/sources/opml.xml?route_token=incorrect")

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end

    test "returns 401 if the route token is missing", %{conn: conn} do
      conn = get(conn, ~p"/sources/opml.xml")

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end
  end

  describe "rss_feed" do
    test "renders the XML document", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source.uuid}/feed" <> ".xml")

      assert conn.status == 200
      assert {"content-type", "application/rss+xml; charset=utf-8"} in conn.resp_headers
      assert {"content-disposition", "inline"} in conn.resp_headers
    end

    test "returns 404 if the source does not exist", %{conn: conn} do
      conn = get(conn, ~p"/sources/00000000-0000-0000-0000-000000000000/feed")

      assert conn.status == 404
      assert conn.resp_body == "Source not found"
    end
  end

  describe "feed_image" do
    test "returns a feed image if one can be found", %{conn: conn} do
      source = source_with_metadata_attachments()

      conn = get(conn, ~p"/sources/#{source.uuid}/feed_image" <> ".jpg")

      assert conn.status == 200
      assert {"content-type", "image/jpeg; charset=utf-8"} in conn.resp_headers
      assert conn.resp_body == File.read!(source.metadata.poster_filepath)
    end

    test "returns 404 if an image cannot be found", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source.uuid}/feed_image" <> ".jpg")

      assert conn.status == 404
      assert conn.resp_body == "Image not found"
    end

    test "returns 404 if the source does not exist", %{conn: conn} do
      conn = get(conn, ~p"/sources/00000000-0000-0000-0000-000000000000/feed_image")

      assert conn.status == 404
      assert conn.resp_body == "Source not found"
    end
  end

  describe "episode_image" do
    test "returns an episode image if one can be found", %{conn: conn} do
      media_item = media_item_with_attachments()

      conn = get(conn, ~p"/media/#{media_item.uuid}/episode_image" <> ".jpg")

      assert conn.status == 200
      assert {"content-type", "image/jpeg; charset=utf-8"} in conn.resp_headers
      assert conn.resp_body == File.read!(media_item.thumbnail_filepath)
    end

    test "returns 404 if an image cannot be found", %{conn: conn} do
      media_item = media_item_fixture()

      conn = get(conn, ~p"/media/#{media_item.uuid}/episode_image" <> ".jpg")

      assert conn.status == 404
      assert conn.resp_body == "Image not found"
    end

    test "returns 404 if the media item does not exist", %{conn: conn} do
      conn = get(conn, ~p"/media/00000000-0000-0000-0000-000000000000/episode_image")

      assert conn.status == 404
      assert conn.resp_body == "Media item not found"
    end
  end
end
