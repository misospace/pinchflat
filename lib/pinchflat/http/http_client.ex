defmodule Pinchflat.HTTP.HTTPClient do
  @moduledoc """
  This module is a thin wrapper around Erlang's `:httpc` so consumers can
  configure it once and tests can swap it out via `Mox`. It also enforces
  sane default connect and request timeouts so a stalled upstream host
  cannot hang a queue worker indefinitely.

  Defaults can be overridden in Application config under
  `:pinchflat, Pinchflat.HTTP.HTTPClient`:

      config :pinchflat, Pinchflat.HTTP.HTTPClient,
        connect_timeout: 5_000,
        request_timeout: 15_000,
        max_body_length: 5_000_000
  """

  @behaviour Pinchflat.HTTP.HTTPBehaviour

  alias Pinchflat.HTTP.HTTPBehaviour

  # `:httpc` defaults both `timeout` and `connect_timeout` to `:infinity`,
  # which means a stalled upstream can pin a worker forever. We override
  # both so the call fails fast instead.
  @default_request_timeout 15_000
  @default_connect_timeout 5_000

  # `:httpc` does not expose a response-size option on the OTP version we use,
  # so responses are streamed and cancelled once this cap is reached. Our
  # consumers only fetch small payloads (RSS feeds, a single API page, one
  # release JSON), so a few MB is ample.
  @default_max_body_length 5_000_000

  @doc """
  Performs a GET request against `url`. Returns `{:ok, body}` on a
  successful response (status 200..299) or `{:error, reason}` otherwise.
  """
  @impl HTTPBehaviour
  def get(url), do: get(url, [], [])

  @impl HTTPBehaviour
  def get(url, headers), do: get(url, headers, [])

  @impl HTTPBehaviour
  def get(url, headers, opts) do
    headers = parse_headers(headers)
    http_opts = [timeout: request_timeout(), connect_timeout: connect_timeout()]

    request_opts =
      Keyword.merge(opts,
        sync: false,
        stream: {:self, :once},
        body_format: :binary,
        full_result: true,
        receiver: self()
      )

    :inets.start()

    case :httpc.request(:get, {url, headers}, http_opts, request_opts) do
      {:ok, request_id} ->
        receive_response(request_id, max_body_length(), [], 0, nil, request_timeout())

      {:error, reason} ->
        request_error(reason)
    end
  end

  defp parse_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist_safe(k), to_charlist_safe(v)} end)
  end

  defp to_charlist_safe(value) when is_binary(value), do: to_charlist(value)
  defp to_charlist_safe(value) when is_list(value), do: value

  defp request_timeout do
    :pinchflat
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:request_timeout, @default_request_timeout)
  end

  defp connect_timeout do
    :pinchflat
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:connect_timeout, @default_connect_timeout)
  end

  defp max_body_length do
    :pinchflat
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_body_length, @default_max_body_length)
  end

  defp receive_response(request_id, max_body_length, body_parts, body_length, handler_pid, timeout) do
    receive do
      {:http, {^request_id, :stream_start, headers, new_handler_pid}} ->
        if response_body_too_large?(content_length(headers), max_body_length) do
          response_too_large(request_id, max_body_length)
        else
          :httpc.stream_next(new_handler_pid)
          receive_response(request_id, max_body_length, body_parts, body_length, new_handler_pid, timeout)
        end

      {:http, {^request_id, :stream_start, headers}} ->
        if response_body_too_large?(content_length(headers), max_body_length) do
          response_too_large(request_id, max_body_length)
        else
          receive_response(request_id, max_body_length, body_parts, body_length, nil, timeout)
        end

      {:http, {^request_id, :stream, body_part}} ->
        body_part = IO.iodata_to_binary(body_part)
        new_body_length = body_length + byte_size(body_part)

        if response_body_too_large?(new_body_length, max_body_length) do
          response_too_large(request_id, max_body_length)
        else
          maybe_stream_next(handler_pid)
          receive_response(request_id, max_body_length, [body_part | body_parts], new_body_length, handler_pid, timeout)
        end

      {:http, {^request_id, :stream_end, _headers}} ->
        if response_body_too_large?(body_length, max_body_length) do
          response_too_large(request_id, max_body_length)
        else
          {:ok, body_parts |> Enum.reverse() |> IO.iodata_to_binary()}
        end

      {:http, {^request_id, {:error, reason}}} ->
        request_error(reason)

      {:http, {^request_id, {{_version, status_code, reason_phrase}, _headers, body}}} ->
        body = IO.iodata_to_binary(body)

        cond do
          status_code in 200..299 and response_body_too_large?(byte_size(body), max_body_length) ->
            response_too_large(request_id, max_body_length)

          status_code in 200..299 ->
            {:ok, to_string(body)}

          true ->
            {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}
        end
    after
      timeout ->
        :httpc.cancel_request(request_id)
        request_error(:timeout)
    end
  end

  defp maybe_stream_next(nil), do: :ok
  defp maybe_stream_next(handler_pid), do: :httpc.stream_next(handler_pid)

  defp content_length(headers) do
    case Enum.find(headers, fn {name, _value} -> String.downcase(to_string(name)) == "content-length" end) do
      {_name, value} ->
        case Integer.parse(String.trim(to_string(value))) do
          {length, ""} -> length
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp response_body_too_large?(body_length, max_body_length)
       when is_integer(body_length) and is_integer(max_body_length),
       do: body_length > max_body_length

  defp response_body_too_large?(_body_length, _max_body_length), do: false

  defp response_too_large(request_id, max_body_length) do
    :httpc.cancel_request(request_id)
    {:error, "HTTP response body exceeded max_body_length of #{max_body_length} bytes"}
  end

  defp request_error(reason), do: {:error, "HTTP request failed: #{inspect(reason)}"}
end
