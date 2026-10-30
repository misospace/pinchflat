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
  Removes a metadata tmpfile and the empty namespace directories that
  `generate_metadata_tmpfile/1` created for it.

  Only point this at tmpfiles THIS process generated via
  `generate_metadata_tmpfile/1`. It is not for paths owned by other processes
  and it never bulk-purges the tmpfile directory: `File.rmdir/1` only
  succeeds on empty directories, so sibling files from other jobs are never
  touched. (A sibling's namespace directory could in theory be removed in
  the microseconds between its creation and its file being written; the
  generator's `write_p!` surfaces that as an error and Oban retries.)

  For namespace-shaped paths, cleanup also refuses to run - with a warning -
  unless both namespace directories are real directories per `File.lstat/1`.
  `File.rm/1` follows symlinked parent directories, so without this check a
  process that can write under the tmpfile root could redirect cleanup into
  another directory and have it delete a same-named file there. That is
  best-effort containment for a shared root, not a closed race: it removes
  the systematic exposure, and a swap landing between this check and the
  unlink would need openat-style unlinking that the stdlib does not expose.

  Returns :ok
  """
  def cleanup_metadata_tmpfile(filepath) do
    if namespaced_tmpfile_path?(filepath) && !namespace_free_of_symlinks?(filepath) do
      Logger.warning("Refusing to clean metadata tmpfile #{filepath}: a namespace directory is not a real directory")
    else
      File.rm(filepath)

      if namespaced_tmpfile_path?(filepath) do
        parent = Path.dirname(filepath)
        File.rmdir(parent)
        File.rmdir(Path.dirname(parent))
      end
    end

    :ok
  end

  defp namespaced_tmpfile_path?(filepath) do
    if Path.type(filepath) == :absolute do
      tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
      namespace = Path.dirname(Path.relative_to(filepath, tmpfile_directory))

      namespace =~ ~r"^[^/]{2}/[^/]{2}$"
    else
      false
    end
  end

  # `File.lstat/1` does not follow symlinks, so a `:directory` type proves the
  # component is a real directory rather than a redirect. A missing directory
  # counts as safe: there is nothing to unlink or traverse then, and cleanup
  # must stay idempotent for files that are already gone. Any other stat error
  # (permissions and friends) refuses - leaking a tmpfile beats mis-deleting.
  defp namespace_free_of_symlinks?(filepath) do
    parent = Path.dirname(filepath)

    Enum.all?([parent, Path.dirname(parent)], fn dir ->
      case File.lstat(dir) do
        {:ok, %File.Stat{type: :directory}} -> true
        {:error, :enoent} -> true
        _other -> false
      end
    end)
  end

  @doc """
  Removes a per-invocation scratch directory that this process generated directly
  beneath the tmpfile directory - eg. the random image directory the source-metadata
  worker hands to yt-dlp.

  Only point this at directories THIS process generated with a random name under
  the tmpfile root. It is not for caller- or metadata-derived paths: cleanup
  refuses - with a warning - any path that is not a real directory (per
  `File.lstat/1`, so a symlink cannot redirect removal) located directly under
  the tmpfile directory, and the tmpfile directory itself never qualifies.
  `File.rm_rf/1` unlinks rather than descends into symlinks, so a planted link
  inside the directory is removed as a link, not followed. Removal failure is
  logged and swallowed: leaking a scratch directory beats crashing the job.
  Like `cleanup_metadata_tmpfile/1`'s guard, this is best-effort containment
  for a shared root, not a closed race: a swap landing between the `lstat`
  check and the removal would need openat-style unlinking the stdlib does not
  expose.

  Returns :ok
  """
  def cleanup_tmpfile_directory(directory) when is_binary(directory) do
    case File.lstat(directory) do
      # Nothing was ever created (or it is already gone): a benign no-op, matching
      # `cleanup_metadata_tmpfile/1`'s enoent handling.
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        if directly_under_tmpfile_root?(directory) do
          remove_tmpfile_directory(directory)
        else
          Logger.warning("Refusing to clean tmpfile directory #{directory}: not directly under the tmpfile directory")

          :ok
        end

      # A file or a symlink (dangling or not): refusing - with a warning - beats
      # unlinking something this process did not generate as a directory.
      _other ->
        Logger.warning(
          "Refusing to clean tmpfile directory #{directory}: not a real directory directly under the tmpfile directory"
        )

        :ok
    end
  end

  defp remove_tmpfile_directory(directory) do
    case File.rm_rf(directory) do
      {:ok, _removed} ->
        :ok

      {:error, reason, _path} ->
        Logger.warning("Failed to clean tmpfile directory #{directory}: #{inspect(reason)}")

        :ok
    end
  end

  defp directly_under_tmpfile_root?(directory) do
    Path.type(directory) == :absolute &&
      Path.dirname(directory) == Application.get_env(:pinchflat, :tmpfile_directory)
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

  Callers: `Media.delete_media_files/2` and `Media.delete_media_item/2` treat
  `:enoent` as success, and for any other reason log a warning and return
  `{:error, {:file_removal_failed, [{filepath, reason}]}}` — the latter, unless told
  to `ignore_file_removal_errors`. The discarding callers are
  `Sources.delete_source_files/1`, `Sources.delete_internal_metadata_files/1`,
  `Media.delete_internal_metadata_files/1`, and `FileSyncing.handle_file_deletion/2`.

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

      # A non-empty directory (or one that no longer exists) is the expected
      # stop condition for the walk, not an error worth surfacing.
      {:error, :eexist} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
