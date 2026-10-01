defmodule PinchflatWeb.EndpointTest do
  use PinchflatWeb.ConnCase, async: false

  describe "websocket security options" do
    test "declares the LiveView CSRF check and retains session info" do
      assert {"/live", Phoenix.LiveView.Socket, websocket: [check_csrf: true, connect_info: [session: session_options]]} =
               Enum.find(PinchflatWeb.Endpoint.__sockets__(), fn {path, _, _} -> path == "/live" end)

      assert Keyword.fetch!(session_options, :store) == :cookie
      assert PinchflatWeb.Endpoint.config(:check_origin) == false
    end

    test "declares the live-reload origin policy inside the code-reloading guard" do
      endpoint_ast = endpoint_source() |> Code.string_to_quoted!()

      assert live_reload_socket_options(endpoint_ast) == [check_origin: :conn]
    end

    test "accepts a same-origin request and rejects a foreign origin with :conn" do
      same_origin_conn = Plug.Test.conn(:get, "/") |> put_req_header("origin", "http://www.example.com:80")

      checked_same_origin_conn = check_live_reload_origin(same_origin_conn)

      refute checked_same_origin_conn.halted

      foreign_origin_conn = Plug.Test.conn(:get, "/") |> put_req_header("origin", "http://example.com:80")

      checked_foreign_origin_conn = check_live_reload_origin(foreign_origin_conn)

      assert checked_foreign_origin_conn.status == 403
      assert checked_foreign_origin_conn.halted
    end

    defp endpoint_source do
      File.read!(Path.join(File.cwd!(), "lib/pinchflat_web/endpoint.ex"))
    end

    defp live_reload_socket_options(ast) do
      {_ast, socket_options} =
        Macro.prewalk(ast, nil, fn
          {:if, _, [{:code_reloading?, _, _}, clauses]} = node, nil ->
            socket_options = clauses |> Keyword.fetch!(:do) |> find_live_reload_socket_options()
            {node, socket_options}

          node, socket_options ->
            {node, socket_options}
        end)

      socket_options
    end

    defp find_live_reload_socket_options(ast) do
      {_ast, socket_options} =
        Macro.prewalk(ast, nil, fn
          {:socket, _, ["/phoenix/live_reload/socket", _socket_module, options]} = node, nil ->
            {node, Keyword.get(options, :websocket)}

          node, socket_options ->
            {node, socket_options}
        end)

      socket_options
    end

    defp check_live_reload_origin(conn) do
      Phoenix.Socket.Transport.check_origin(
        conn,
        Phoenix.LiveReloader.Socket,
        PinchflatWeb.Endpoint,
        check_origin: :conn
      )
    end
  end

  describe "static file serving" do
    test "serves digested top-level icon filenames instead of routing them", %{conn: conn} do
      # In prod, `~p"/apple-touch-icon.png"` resolves to the digested filename,
      # which Plug.Static's `only:` (literal segment match) rejected — every
      # browser icon request fell through and 404'd in the router. The
      # `only_matching:` prefixes must let these through.
      static_dir = Application.app_dir(:pinchflat, "priv/static")
      digested_filename = "apple-touch-icon-0123456789abcdef.png"
      digested_path = Path.join(static_dir, digested_filename)
      File.cp!(Path.join(static_dir, "apple-touch-icon.png"), digested_path)
      on_exit(fn -> File.rm(digested_path) end)

      conn = get(conn, "/#{digested_filename}")

      assert conn.status == 200
    end
  end
end
