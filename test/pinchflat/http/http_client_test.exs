defmodule Pinchflat.HTTP.HTTPClientTest do
  use ExUnit.Case, async: false

  alias Pinchflat.HTTP.HTTPClient

  setup do
    # Force short timeouts for the test suite so the suite stays fast even
    # when exercising the "stalled upstream" failure path. We restore the
    # original Application config in `on_exit`.
    original_config = Application.get_env(:pinchflat, HTTPClient, [])
    request_timeout = 500
    connect_timeout = 500

    Application.put_env(
      :pinchflat,
      HTTPClient,
      Keyword.merge(original_config, request_timeout: request_timeout, connect_timeout: connect_timeout)
    )

    on_exit(fn ->
      Application.put_env(:pinchflat, HTTPClient, original_config)
    end)

    {:ok, request_timeout: request_timeout, connect_timeout: connect_timeout}
  end

  describe "get/3 timeouts" do
    test "returns an error tuple within the request timeout when upstream accepts the connection but never responds",
         %{request_timeout: request_timeout} do
      {port, cleanup} = start_silent_listener!()

      try do
        url = "http://127.0.0.1:#{port}/"
        bound = request_timeout + 5_000

        assert {result, _elapsed_ms} =
                 run_within(bound, fn ->
                   HTTPClient.get(url, [], [])
                 end)

        assert match?({:error, _reason}, result),
               "expected HTTPClient.get/3 to return {:error, _} within #{bound}ms, got: #{inspect(result)}"
      after
        cleanup.()
      end
    end

    test "returns an error tuple within the connect timeout when the upstream refuses the connection",
         %{connect_timeout: connect_timeout} do
      # Bind to a port and immediately close it so the kernel rejects the
      # next connect attempt with ECONNREFUSED instead of letting it hang.
      {:ok, port} = listen_and_close!()

      url = "http://127.0.0.1:#{port}/"
      bound = connect_timeout + 5_000

      assert {result, _elapsed_ms} =
               run_within(bound, fn ->
                 HTTPClient.get(url, [], [])
               end)

      assert match?({:error, _reason}, result)
    end
  end

  describe "configurable timeouts" do
    test "honours Application-configured request_timeout override" do
      Application.put_env(:pinchflat, HTTPClient, request_timeout: 250, connect_timeout: 5_000)
      {port, cleanup} = start_silent_listener!()

      try do
        url = "http://127.0.0.1:#{port}/"
        bound = 5_000

        assert {result, elapsed_ms} =
                 run_within(bound, fn ->
                   HTTPClient.get(url, [], [])
                 end)

        assert match?({:error, _reason}, result)

        # We gave :httpc 250ms to time out. Allow generous slack for slow
        # CI but still demand the call did not block anywhere near the
        # default 15s we'd otherwise be sitting on.
        assert elapsed_ms < 3_000,
               "expected call to fail well under the default 15s timeout, but it took #{elapsed_ms}ms"
      after
        cleanup.()
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Starts a TCP listener on a free port and returns `{port, cleanup}` where
  # `cleanup/0` shuts the listener down. Every incoming connection is accepted
  # and then held open without ever writing an HTTP response — the worst-case
  # "stalled upstream" we want :httpc to time out on.
  defp start_silent_listener! do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    pid = spawn(fn -> accept_loop(listen_socket) end)

    cleanup = fn ->
      :gen_tcp.close(listen_socket)

      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end

    {port, cleanup}
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        # Hold the socket open so the kernel doesn't reset the connection.
        # Never reply with an HTTP response.
        Process.sleep(:infinity)
        :gen_tcp.close(socket)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok
    end
  end

  defp listen_and_close! do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    :gen_tcp.close(listen_socket)
    {:ok, port}
  end

  # Runs `fun` and returns `{result, elapsed_ms}`. If `fun` does not return
  # within `bound_ms`, the test fails loudly rather than hanging the suite.
  defp run_within(bound_ms, fun) do
    parent = self()
    start_time = System.monotonic_time(:millisecond)

    pid =
      spawn(fn ->
        result = fun.()
        send(parent, {:done, result, System.monotonic_time(:millisecond)})
      end)

    receive do
      {:done, result, end_time} ->
        {result, end_time - start_time}
    after
      bound_ms ->
        Process.exit(pid, :kill)

        flunk("HTTPClient.get/3 did not return within #{bound_ms}ms — the timeout configuration is not being honoured")
    end
  end
end
