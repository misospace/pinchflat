defmodule Pinchflat.Boot.ConfigHelpers do
  @moduledoc """
  Helpers for safely parsing runtime configuration values (typically read from
  environment variables) without crashing the application on malformed input.

  Used by `config/runtime.exs` so that a typo or accidental non-numeric value
  in the environment can never bring down the boot.
  """

  @doc """
  Reads the environment variable named `name` and parses it as an integer.

  Returns `default` when the variable is unset, blank, or cannot be parsed as
  an integer. The default is also returned when the variable parses as a
  non-integer (e.g. `"1.5"`) or has trailing junk (e.g. `"12abc"`).

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

      value when value in ["", " "] ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end
end
