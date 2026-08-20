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
        request_timeout: 15_000
  """

  @behaviour Pinchflat.HTTP.HTTPBehaviour

  alias Pinchflat.HTTP.HTTPBehaviour

  # `:httpc` defaults both `timeout` and `connect_timeout` to `:infinity`,
  # which means a stalled upstream can pin a worker forever. We override
  # both so the call fails fast instead.
  @default_request_timeout 15_000
  @default_connect_timeout 5_000

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

    :inets.start()

    case :httpc.request(:get, {url, headers}, http_opts, opts) do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} ->
        {:ok, to_string(body)}

      {:ok, {{_version, status_code, reason_phrase}, _headers, _body}} ->
        {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
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
end
