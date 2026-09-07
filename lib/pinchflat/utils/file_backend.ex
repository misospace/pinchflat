defmodule Pinchflat.Utils.FileBackend do
  @moduledoc """
  Behaviour for filesystem operations that need to be stubbable in tests.

  The default implementation is `Pinchflat.Utils.RealFileBackend`, which delegates
  straight to the corresponding `File` functions. Tests swap in a Mox mock (see
  `test/test_helper.exs`) to deterministically exercise error paths that are hard
  to reproduce against a real filesystem (e.g. a directory that refuses to be
  removed because of POSIX permissions or a read-only mount).
  """

  @callback rmdir(Path.t()) :: :ok | {:error, File.posix()}
end
