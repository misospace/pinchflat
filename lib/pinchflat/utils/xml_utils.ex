defmodule Pinchflat.Utils.XmlUtils do
  @moduledoc """
  Utilities for working with XML.
  """

  # XML 1.0 only allows tab (0x09), LF (0x0A), CR (0x0D) and printable
  # Unicode in element text and CDATA sections. Everything else in the
  # 0x00-0x1F range is forbidden and makes the document not well-formed.
  @forbidden_codepoints MapSet.new(Enum.to_list(0x00..0x08) ++ [0x0B, 0x0C] ++ Enum.to_list(0x0E..0x1F))

  @doc """
  Escapes a string for safe inclusion in XML element text.
  """
  def safe(value) when is_binary(value) do
    value
    |> strip_forbidden_chars()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  def safe(value), do: safe(to_string(value))

  @doc """
  Escapes a string for safe inclusion in a CDATA section.
  """
  def escape_cdata(value) when is_binary(value) do
    value
    |> strip_forbidden_chars()
    |> String.replace("]]>", "]]]]><![CDATA[>")
  end

  def escape_cdata(value), do: escape_cdata(to_string(value))

  @doc """
  Strips XML 1.0 forbidden control characters (0x00-0x08, 0x0B, 0x0C,
  0x0E-0x1F) from a string.
  """
  def strip_forbidden_chars(value) when is_binary(value) do
    value
    |> :unicode.characters_to_list(:utf8)
    |> Enum.reject(&(&1 in @forbidden_codepoints))
    |> :unicode.characters_to_binary(:utf8)
  end
end
