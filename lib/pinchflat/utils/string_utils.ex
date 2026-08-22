defmodule Pinchflat.Utils.StringUtils do
  @moduledoc """
  Utility methods for working with strings
  """

  @doc """
  Converts a string to kebab-case (ie: `hello world` -> `hello-world`)

  Returns binary()
  """
  def to_kebab_case(string) do
    string
    |> String.replace(~r/[\s_]/, "-")
    |> String.downcase()
  end

  @doc """
  Returns a random string of the given length. Base 16 encoded, lower case.

  Returns binary()
  """
  def random_string(length \\ 32) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode16(case: :lower)
    |> String.slice(0..(length - 1))
  end

  @doc """
  Escapes a string for use as a quoted-string filename in a
  `Content-Disposition` header (RFC 6266). Backslashes and double quotes are
  escaped and control characters (including CR/LF) are percent-encoded so the
  header value remains a single, well-formed line.

  Returns binary()
  """
  def to_content_disposition_filename(string) when is_binary(string) do
    string
    |> String.replace(~r/[\x00-\x1F\x7F]/, &percent_encode_char/1)
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp percent_encode_char(<<codepoint>>) do
    "%" <> String.upcase(String.pad_leading(Integer.to_string(codepoint, 16), 2, "0"))
  end

  @doc """
  Wraps a string in double braces. Useful as a UI helper now that
  LiveView 1.0.0 allows `{}` for interpolation so now we can't use braces
  directly in the view.

  Returns binary()
  """
  def double_brace(string) do
    "{{ #{string} }}"
  end

  @doc """
  Wraps a string in quotes if it's not already a string. Useful for working with
  error messages whose types can vary.

  Returns binary()
  """
  def wrap_string(message) when is_binary(message), do: message
  def wrap_string(message), do: "#{inspect(message)}"
end
