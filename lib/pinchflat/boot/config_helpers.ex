defmodule Pinchflat.Boot.ConfigHelpers do
  @moduledoc """
  Helpers for safely parsing runtime configuration values (typically read from
  environment variables) without crashing the application on malformed input.

  Used by `config/runtime.exs` so that a typo or accidental non-numeric value
  in the environment can never bring down the boot.
  """

  require Logger

  @doc """
  Reads the environment variable named `name` and parses it as an integer.

  Returns `default` when the variable is unset, blank, or cannot be parsed as
  an integer. The default is also returned when the variable parses as a
  non-integer (e.g. `"1.5"`) or has trailing junk (e.g. `"12abc"`).

  When the variable is set but cannot be parsed, a warning is logged naming
  the variable, the rejected value, and the default being used. Nothing is
  logged when the variable is unset or parses cleanly — an unset variable
  is normal operation, not a misconfiguration.

  ## Examples

      iex> safe_int_env("MY_VAR", 10)
      #=> 10   # when MY_VAR is unset or malformed

      iex> System.put_env("MY_VAR", "42"); safe_int_env("MY_VAR", 10)
      42
  """
  @spec safe_int_env(String.t(), integer()) :: integer()
  def safe_int_env(name, default) when is_binary(name) and is_integer(default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} ->
            parsed

          _ ->
            Logger.warning("#{name}=#{inspect(value)} is not a valid integer; using default #{default}")

            default
        end
    end
  end

  # Plug's cookie store requires conn.secret_key_base to be at least 64 bytes.
  @secret_key_base_min_bytes 64

  @doc """
  Resolves a Plug-compatible `secret_key_base` (at least 64 bytes).

  `env_value` is the value of the `SECRET_KEY_BASE` environment variable
  (`nil` when unset). `persisted_path` is where the self-hosted secret is
  stored on disk.

  - A non-blank `env_value` of at least 64 bytes is returned as-is: an
    explicitly supplied secret remains the source of truth and is never
    overwritten on disk.
  - A too-short `env_value` is rejected with a warning and the persisted
    secret is used instead (regenerated if it is missing or also too short).
  - When `env_value` is unset, the persisted file is read. A persisted value
    of at least 64 bytes is returned unchanged, so the secret is stable
    across restarts. A missing or too-short persisted value is replaced with
    a freshly generated 64-byte secret, which is written back to
    `persisted_path` (creating parent directories as needed).
  """
  @spec resolve_secret_key_base(String.t() | nil, String.t()) :: String.t()
  def resolve_secret_key_base(env_value, persisted_path) when is_binary(persisted_path) do
    case env_value do
      nil ->
        load_or_generate(persisted_path)

      value when byte_size(value) >= @secret_key_base_min_bytes ->
        value

      value ->
        Logger.warning(
          "SECRET_KEY_BASE is #{byte_size(value)} bytes; Plug requires at least " <>
            "#{@secret_key_base_min_bytes}. Falling back to the persisted secret at #{persisted_path}."
        )

        load_or_generate(persisted_path)
    end
  end

  defp load_or_generate(path) do
    case File.read(path) do
      {:ok, raw} ->
        value = String.trim(raw)

        if byte_size(value) >= @secret_key_base_min_bytes do
          value
        else
          regenerate(path, value)
        end

      {:error, _} ->
        persist_new(path)
    end
  end

  defp regenerate(path, value) do
    Logger.warning(
      "Persisted secret at #{path} is #{byte_size(value)} bytes; Plug requires at least " <>
        "#{@secret_key_base_min_bytes}. Regenerating."
    )

    persist_new(path)
  end

  defp persist_new(path) do
    secret = generate_secret_key_base()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, secret)
    secret
  end

  # 48 random bytes -> 64 base64url characters without padding, which meets
  # Plug's 64-byte minimum exactly.
  defp generate_secret_key_base do
    Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
  end
end
