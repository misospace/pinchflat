defmodule Pinchflat.Utils.RealFileBackend do
  @moduledoc false
  @behaviour Pinchflat.Utils.FileBackend

  @impl true
  def rmdir(path), do: File.rmdir(path)
end
