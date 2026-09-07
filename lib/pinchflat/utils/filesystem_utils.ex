defmodule Pinchflat.Utils.FilesystemUtils do
  @moduledoc """
  Utility methods for working with the filesystem
  """
  require Logger

  alias Pinchflat.Media
  alias Pinchflat.Utils.StringUtils

  @doc """
  Checks if a file exists and has non-whitespace contents.

  Returns boolean()
  """
  def exists_and_nonempty?(filepath) do
    case File.read(filepath) do
      {:ok, contents} ->
        String.trim(contents) != ""

      _ ->
        false
    end
  end

  @doc """
  Checks if two filepaths reference the same file.

  Useful if you have a relative and absolute filepath and want to be sure they're the same file.
  Also works with symlinks.

  Returns boolean()
  """
  def filepaths_reference_same_file?(filepath_1, filepath_2) do
    {:ok, stat_1} = File.stat(filepath_1)
    {:ok, stat_2} = File.stat(filepath_2)

    identifier_1 = "#{stat_1.major_device}:#{stat_1.minor_device}:#{stat_1.inode}"
    identifier_2 = "#{stat_2.major_device}:#{stat_2.minor_device}:#{stat_2.inode}"

    identifier_1 == identifier_2
  end

  @doc """
  Generates a temporary file and returns its path. The file is empty and has the given type.
  Generates all the directories in the path if they don't exist.

  Returns binary()
  """
  def generate_metadata_tmpfile(type) do
    filename = StringUtils.random_string(64)
    # This "namespacing" is more to help with development since things get
    # weird in my editor when there are thousands of files in a single directory
    first_two = String.slice(filename, 0..1)
    second_two = String.slice(filename, 2..3)
    tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)

    filepath =
      Path.join([
        tmpfile_directory,
        first_two,
        second_two,
        "#{filename}.#{type}"
      ])

    :ok = write_p!(filepath, "")

    filepath
  end

  @doc """
  Writes content to a file, creating directories as needed.
  Takes the same args as File.write/3.

  Returns :ok | {:error, any()}
  """
  def write_p(file, content, modes \\ []) do
    dirname = Path.dirname(file)

    case File.mkdir_p(dirname) do
      :ok -> File.write(file, content, modes)
      err -> err
    end
  end

  @doc """
  Writes content to a file, creating directories as needed.
  Takes the same args as File.write!/3.

  Returns :ok | raises on error
  """
  def write_p!(filepath, content, modes \\ []) do
    :ok = write_p(filepath, content, modes)
  end

  @doc """
  Copies a file from source to destination, creating directories as needed.

  Returns :ok | raises on error
  """
  def cp_p!(source, destination) do
    destination
    |> Path.dirname()
    |> File.mkdir_p!()

    File.cp!(source, destination)
  end

  @doc """
  Fetches the file size of a media item and saves it to the database.

  Returns {:ok, media_item} | {:error, any()}
  """
  def compute_and_save_media_filesize(media_item) do
    case File.stat(media_item.media_filepath) do
      {:ok, %{size: size}} ->
        Media.update_media_item(media_item, %{media_size_bytes: size})

      err ->
        err
    end
  end

  @doc """
  Deletes a file and removes any empty directories in the path.
  Does NOT remove any directories that are not empty.

  If the file itself cannot be removed the underlying error tuple is returned.
  If the file is removed but empty-directory cleanup fails part-way through
  (e.g. permission, I-O, or readonly-fs errors from `File.rmdir/1`), the
  error is logged via `Logger.warning/1` and `:ok` is still returned —
  the callers of this function expect an `:ok` on a successful file delete,
  and silent accumulation of empty parent directories is the failure mode
  this function exists to prevent, not to surface to upstream callers.

  Callers: `Media.delete_media_item/2`, `Media.delete_media_files/2`,
  `Media.delete_internal_metadata_files/1`, `Sources.delete_source/2`,
  `Sources.delete_source_files/1`, `Sources.delete_internal_metadata_files/1`,
  and `FileSyncing.handle_file_deletion/2`. None of these inspect the return
  value — every call site is either a discarded `Enum.each/2` callback
  or a discarded expression in an `if` block — so the
  `:ok`-on-partial-cleanup-failure contract is preserved without any
  observable contract change for upstream callers.

  Returns :ok | {:error, any()}
  """
  def delete_file_and_remove_empty_directories(filepath) do
    case File.rm(filepath) do
      :ok ->
        case filepath |> Path.dirname() |> recursively_delete_empty_directories() do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to remove empty directories for #{filepath}: #{inspect(reason)}")

            :ok
        end

      err ->
        err
    end
  end

  @doc """
  Recursively removes empty directories walking up from `directory` until it
  hits a directory that is non-empty (or no longer exists).

  Returns `:ok` if every directory along the walk was empty and could be
  removed, or `{:error, reason}` if a permission / I-O / readonly-fs error
  halted the walk before completion.
  """
  def recursively_delete_empty_directories(directory) do
    backend = Application.get_env(:pinchflat, :file_backend, Pinchflat.Utils.RealFileBackend)

    case backend.rmdir(directory) do
      :ok ->
        directory
        |> Path.dirname()
        |> recursively_delete_empty_directories()

      # A non-empty directory is the expected stop condition for the walk —
      # benign in its own right, but worth a debug line so operators can
      # distinguish "walk hit a non-empty parent" from "nothing to do" (the
      # :enoent case below) when triaging missing-directory reports.
      {:error, :eexist} ->
        Logger.debug("Empty-directory walk stopped at non-empty parent #{directory}")

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
