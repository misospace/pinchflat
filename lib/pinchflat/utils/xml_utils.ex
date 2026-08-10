defmodule Pinchflat.Utils.XmlUtils do
  @moduledoc """
  Utility methods for working with XML documents
  """

  @doc """
  Escapes invalid XML characters in a string

  Returns binary()
  """
  def safe(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  @doc """
  Escapes `]]>` sequences in a string that will be embedded in CDATA.

  The sequence `]]>` terminates a CDATA section, so user-controlled content
  containing it must be escaped to prevent feed poisoning / XML injection.
  The standard approach is to split `]]>` as `]]]]><![CDATA[>`.

  Returns binary()
  """
  def escape_cdata(""), do: ""

  def escape_cdata(value) do
    value |> to_string() |> String.replace("]]>", "]]]]><![CDATA[>")
  end
end
