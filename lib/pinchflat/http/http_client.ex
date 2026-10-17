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
        max_body_length: 5_000_000,
        max_redirects: 5

  HTTP 301/302/303/307/308 redirects are followed automatically, up to
  `max_redirects` hops. `:httpc`'s built-in `autoredirect` is deliberately
  not used: it follows at most 5 hops with no configurable cap and then
  surfaces the raw 3xx as if it were the final answer, and it crashes on
  unparseable or foreign-scheme `Location` values. Redirects are resolved
  here instead; each hop gets a fresh `request_timeout`, so worst-case wall
  time scales with the hop count rather than being bounded by a single
  deadline, and the original request headers are re-sent on every hop —
  do not pass credential-bearing headers to `get/3`.
  """

  @behaviour Pinchflat.HTTP.HTTPBehaviour

  alias Pinchflat.HTTP.HTTPBehaviour

  # `:httpc` defaults both `timeout` and `connect_timeout` to `:infinity`,
  # which means a stalled upstream can pin a worker forever. We override
  # both so the call fails fast instead.
  @default_request_timeout 15_000
  @default_connect_timeout 5_000

  # `:httpc` does not expose a response-size option on the OTP version we use,
  # so responses are buffered and rejected once this cap is reached. Our
  # consumers only fetch small payloads (RSS feeds, a single API page, one
  # release JSON), so a few MB is ample.
  @default_max_body_length 5_000_000

  # Redirect statuses this client will follow. 300/304/etc. are treated as
  # ordinary non-2xx failures since they do not carry a usable follow-on
  # location for a plain GET.
  @redirect_statuses [301, 302, 303, 307, 308]

  @default_max_redirects 5

  @doc """
  Performs a GET request against `url`, following HTTP 301/302/303/307/308
  redirects up to the configured `max_redirects` (default 5). Returns
  `{:ok, body}` on a successful final response (status 200..299) or
  `{:error, reason}` otherwise — including when the redirect limit is
  exceeded or a redirect lacks a usable `Location` header.
  """
  @impl HTTPBehaviour
  def get(url), do: get(url, [], [])

  @impl HTTPBehaviour
  def get(url, headers), do: get(url, headers, [])

  @impl HTTPBehaviour
  def get(url, headers, opts) do
    ctx = %{url: url, headers: headers, opts: opts, max_redirects: max_redirects()}

    do_get(ctx, ctx.max_redirects)
  end

  defp do_get(ctx, redirects_remaining) do
    headers = parse_headers(ctx.headers)

    # `autoredirect` is pinned to `false` on purpose. `:httpc`'s own redirect
    # following silently caps at 5 internal hops and then surfaces the raw 3xx
    # as if it were the final answer (or crashes outright on an unparseable or
    # foreign-scheme `Location`), and it exposes no configurable hop count.
    # Handling redirects here keeps the cap configurable and the failure modes
    # explicit.
    http_opts = [timeout: request_timeout(), connect_timeout: connect_timeout(), autoredirect: false]

    request_opts =
      Keyword.merge(ctx.opts,
        sync: false,
        body_format: :binary,
        full_result: true,
        receiver: self()
      )

    :inets.start()

    case :httpc.request(:get, {ctx.url, headers}, http_opts, request_opts) do
      {:ok, request_id} ->
        receive_response(request_id, ctx, redirects_remaining)

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

  defp max_redirects do
    :pinchflat
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_redirects, @default_max_redirects)
  end

  defp receive_response(request_id, ctx, redirects_remaining) do
    receive do
      {:http, {^request_id, {:error, reason}}} ->
        request_error(reason)

      {:http, {^request_id, {{_version, status_code, reason_phrase}, resp_headers, body}}} ->
        body = IO.iodata_to_binary(body)

        cond do
          redirect_status?(status_code) and redirects_remaining > 0 ->
            follow_redirect(status_code, reason_phrase, resp_headers, ctx, redirects_remaining)

          redirect_status?(status_code) ->
            {:error, "HTTP request failed: redirect limit of #{ctx.max_redirects} exceeded"}

          status_code in 200..299 and response_body_too_large?(byte_size(body), max_body_length()) ->
            response_too_large(max_body_length())

          status_code in 200..299 ->
            {:ok, to_string(body)}

          true ->
            {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}
        end
    after
      request_timeout() ->
        :httpc.cancel_request(request_id)
        request_error(:timeout)
    end
  end

  defp redirect_status?(status_code), do: status_code in @redirect_statuses

  defp follow_redirect(status_code, reason_phrase, resp_headers, ctx, redirects_remaining) do
    case redirect_target(resp_headers, ctx.url) do
      {:ok, next_url} ->
        do_get(%{ctx | url: next_url}, redirects_remaining - 1)

      :error ->
        {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}
    end
  end

  # Resolves the `Location` header against the URL that produced the
  # redirect, accepting both absolute and relative targets. Anything
  # missing, unparseable, or pointing at a non-HTTP(S) scheme is treated
  # as an unusable redirect.
  defp redirect_target(resp_headers, base_url) do
    case find_header(resp_headers, "location") do
      nil ->
        :error

      value ->
        try do
          case URI.merge(base_url, to_string(value)) do
            %URI{scheme: scheme} = uri when scheme in ["http", "https"] ->
              {:ok, URI.to_string(uri)}

            _ ->
              :error
          end
        rescue
          ArgumentError -> :error
        end
    end
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if key |> to_string() |> String.downcase() == name, do: value
    end)
  end

  defp response_body_too_large?(body_length, max_body_length)
       when is_integer(body_length) and is_integer(max_body_length),
       do: body_length > max_body_length

  defp response_body_too_large?(_body_length, _max_body_length), do: false

  defp response_too_large(max_body_length) do
    {:error, "HTTP response body exceeded max_body_length of #{max_body_length} bytes"}
  end

  defp request_error(reason), do: {:error, "HTTP request failed: #{inspect(reason)}"}
end
