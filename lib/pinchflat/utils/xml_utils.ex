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
  Escapes the CDATA closing sequence `]]>` to prevent CDATA break-out.

  Replaces each occurrence of `]]>` with `]]]]><![CDATA[>`, which safely
  splits the CDATA section so that the parser sees the first `]]>` as
  ending an empty CDATA block, then starts a new one containing `>`.

  Returns binary()
  """
  def escape_cdata(value) when is_binary(value) do
    String.replace(value, "]]>", "]]]]><![CDATA[>")
  end

  def escape_cdata(value) do
    value
    |> to_string()
    |> escape_cdata()
  end
end
