defmodule Pinchflat.Utils.FilesystemUtilsTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Utils.FilesystemUtils

  describe "exists_and_nonempty?" do
    test "returns true if a file exists and has contents" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
      File.write(filepath, "{}")

      assert FilesystemUtils.exists_and_nonempty?(filepath)

      File.rm!(filepath)
    end

    test "returns false if a file doesn't exist" do
      refute FilesystemUtils.exists_and_nonempty?("/nonexistent/file.json")
    end

    test "returns false if a file exists but is empty" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)

      refute FilesystemUtils.exists_and_nonempty?(filepath)

      File.rm!(filepath)
    end

    test "trims the contents before checking" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
      File.write(filepath, "  \n\n  \r\n  ")

      refute FilesystemUtils.exists_and_nonempty?(filepath)

      File.rm!(filepath)
    end
  end

  describe "filepaths_reference_same_file?/2" do
    setup do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)

      on_exit(fn -> File.rm!(filepath) end)

      {:ok, %{filepath: filepath}}
    end

    test "returns true if the files are the same", %{filepath: filepath} do
      assert FilesystemUtils.filepaths_reference_same_file?(filepath, filepath)
    end

    test "returns true if different filepaths point to the same file", %{filepath: filepath} do
      short_path = Path.expand(filepath)
      long_path = Path.join(["/tmp", "..", filepath])

      assert short_path != long_path
      assert FilesystemUtils.filepaths_reference_same_file?(short_path, long_path)
    end

    test "returns true if the files are symlinked", %{filepath: filepath} do
      tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
      other_filepath = Path.join([tmpfile_directory, "symlink.json"])
      :ok = File.ln_s!(filepath, other_filepath)

      assert FilesystemUtils.filepaths_reference_same_file?(filepath, other_filepath)

      File.rm!(other_filepath)
    end

    test "returns false if the files are different", %{filepath: filepath} do
      other_filepath = FilesystemUtils.generate_metadata_tmpfile(:json)

      refute FilesystemUtils.filepaths_reference_same_file?(filepath, other_filepath)

      File.rm!(other_filepath)
    end
  end

  describe "generate_metadata_tmpfile/1" do
    test "creates a tmpfile and returns its path" do
      res = FilesystemUtils.generate_metadata_tmpfile(:json)

      assert String.ends_with?(res, ".json")
      assert File.exists?(res)

      File.rm!(res)
    end
  end

  describe "compute_and_save_media_filesize/1" do
    test "updates the media item with the file size" do
      media_item = media_item_with_attachments()

      refute media_item.media_size_bytes

      assert {:ok, media_item} = FilesystemUtils.compute_and_save_media_filesize(media_item)

      assert Repo.reload!(media_item).media_size_bytes
    end

    test "returns the error if operation fails" do
      media_item = media_item_fixture(%{media_filepath: "/nonexistent/file.mkv"})

      assert {:error, _} = FilesystemUtils.compute_and_save_media_filesize(media_item)
    end
  end

  describe "write_p/3" do
    test "writes content to a file" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
      content = "{}"

      assert :ok = FilesystemUtils.write_p(filepath, content)
      assert File.read!(filepath) == content

      File.rm!(filepath)
    end

    test "creates directories as needed" do
      tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
      filepath = Path.join([tmpfile_directory, "foo", "bar", "file.json"])
      content = "{}"

      assert :ok = FilesystemUtils.write_p(filepath, content)
      assert File.read!(filepath) == content

      File.rm!(filepath)
    end
  end

  describe "write_p!/3" do
    test "writes content to a file" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
      content = "{}"

      assert :ok = FilesystemUtils.write_p!(filepath, content)
      assert File.read!(filepath) == content

      File.rm!(filepath)
    end

    test "creates directories as needed" do
      tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
      filepath = Path.join([tmpfile_directory, "foo", "bar", "file.json"])
      content = "{}"

      assert :ok = FilesystemUtils.write_p!(filepath, content)
      assert File.read!(filepath) == content

      File.rm!(filepath)
    end
  end

  describe "delete_file_and_remove_empty_directories/1" do
    test "deletes file at the provided filepath" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)

      assert File.exists?(filepath)

      assert :ok = FilesystemUtils.delete_file_and_remove_empty_directories(filepath)

      refute File.exists?(filepath)
    end

    test "deletes empty directories" do
      tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
      filepath = Path.join([tmpfile_directory, "foo", "bar", "baz", "qux.json"])
      FilesystemUtils.write_p!(filepath, "")

      assert :ok = FilesystemUtils.delete_file_and_remove_empty_directories(filepath)

      refute File.exists?(filepath)
      refute File.exists?(Path.join([tmpfile_directory, "foo", "bar", "baz"]))
      refute File.exists?(Path.join([tmpfile_directory, "foo", "bar"]))
      refute File.exists?(Path.join([tmpfile_directory, "foo"]))
    end

    test "does not delete directories with other files in them" do
      tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
      filepath_1 = Path.join([tmpfile_directory, "foo", "bar", "baz", "qux.json"])
      filepath_2 = Path.join([tmpfile_directory, "foo", "baz.json"])
      FilesystemUtils.write_p!(filepath_1, "")
      FilesystemUtils.write_p!(filepath_2, "")

      assert :ok = FilesystemUtils.delete_file_and_remove_empty_directories(filepath_1)

      refute File.exists?(filepath_1)
      refute File.exists?(Path.join([tmpfile_directory, "foo", "bar", "baz"]))
      refute File.exists?(Path.join([tmpfile_directory, "foo", "bar"]))

      assert File.exists?(filepath_2)
      assert File.exists?(Path.join([tmpfile_directory, "foo"]))

      # cleanup
      FilesystemUtils.delete_file_and_remove_empty_directories(filepath_2)
    end

    test "returns an error if file could not be deleted" do
      filepath = "/nonexistent/file.json"

      assert {:error, _} = FilesystemUtils.delete_file_and_remove_empty_directories(filepath)
    end

    test "logs an error if an empty directory could not be removed" do
      filepath = FilesystemUtils.generate_metadata_tmpfile(:json)

      # Stub File.rmdir/1 (via the FileBackend behaviour) to fail with
      # :eperm so the empty-directory cleanup step fails deterministically,
      # independent of POSIX permissions or the CI uid.
      stub(FileBackendMock, :rmdir, fn _directory -> {:error, :eperm} end)

      # Bump the logger above the :critical default so capture_log can see
      # the warning emitted by the cleanup path.
      original_level = Logger.level()
      Logger.configure(level: :warning)
      on_exit(fn -> Logger.configure(level: original_level) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = FilesystemUtils.delete_file_and_remove_empty_directories(filepath)
        end)

      # The file is deleted, but the empty directory could not be removed, so
      # the failure must surface in the log rather than being silently dropped.
      assert log =~ "Failed to remove empty directories for #{filepath}"
      assert log =~ ":eperm"
    end
  end

  describe "recursively_delete_empty_directories/1" do
    test "returns :ok when the parent directory contains other files" do
      tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
      filepath = Path.join([tmpfile_directory, "non_empty_walk", "qux.json"])
      FilesystemUtils.write_p!(filepath, "")

      # :eexist is what File.rmdir/1 returns when the directory still has
      # children, which is the expected stop condition for the walk.
      assert :ok = FilesystemUtils.recursively_delete_empty_directories(Path.dirname(filepath))
    end

    test "propagates {:error, :eperm} from File.rmdir/1" do
      directory = FilesystemUtils.generate_metadata_tmpfile(:json) |> Path.dirname()

      stub(FileBackendMock, :rmdir, fn _directory -> {:error, :eperm} end)

      assert {:error, :eperm} = FilesystemUtils.recursively_delete_empty_directories(directory)
    end

    test "treats {:error, :enoent} from File.rmdir/1 as the walk stop" do
      directory = FilesystemUtils.generate_metadata_tmpfile(:json) |> Path.dirname()

      stub(FileBackendMock, :rmdir, fn _directory -> {:error, :enoent} end)

      assert :ok = FilesystemUtils.recursively_delete_empty_directories(directory)
    end
  end

  describe "cp_p!/2" do
    test "copies a file from source to destination" do
      source = "#{tmpfile_directory()}/source.json"
      FilesystemUtils.write_p!(source, "TEST")
      destination = "#{tmpfile_directory()}/destination.json"

      refute File.exists?(destination)
      FilesystemUtils.cp_p!(source, destination)
      assert File.exists?(destination)
      assert File.read!(destination) == "TEST"

      File.rm!(source)
      File.rm!(destination)
    end

    test "creates directories as needed" do
      source = "#{tmpfile_directory()}/source.json"
      FilesystemUtils.write_p!(source, "TEST")
      destination = "#{tmpfile_directory()}/foo/bar/destination.json"

      refute File.exists?(destination)
      FilesystemUtils.cp_p!(source, destination)
      assert File.exists?(destination)

      File.rm!(source)
      File.rm!(destination)
    end
  end

  defp tmpfile_directory do
    Application.get_env(:pinchflat, :tmpfile_directory)
  end
end
