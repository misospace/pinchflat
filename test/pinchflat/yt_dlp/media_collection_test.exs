defmodule Pinchflat.YtDlp.MediaCollectionTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.YtDlp.Media
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.YtDlp.MediaCollection

  @channel_url "https://www.youtube.com/c/PinchflatTestChannel"

  describe "get_media_attributes_for_collection/2" do
    test "returns a list of video attributes with no blank elements" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, source_attributes_return_fixture() <> "\n\n"}
      end)

      assert {:ok, [%Media{media_id: "video1"}, %Media{media_id: "video2"}, %Media{media_id: "video3"}]} =
               MediaCollection.get_media_attributes_for_collection(@channel_url)
    end

    test "passes the expected default args" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, opts, ot, _addl_opts ->
        assert opts == [:simulate, :skip_download, :ignore_no_formats_error, :no_warnings]
        assert ot == Media.indexing_output_template()

        {:ok, ""}
      end)

      assert {:ok, _} = MediaCollection.get_media_attributes_for_collection(@channel_url)
    end

    test "returns the error straight through when the command fails" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:error, "Big issue", 1}
      end)

      assert {:error, "Big issue", 1} = MediaCollection.get_media_attributes_for_collection(@channel_url)
    end

    test "passes long additional command options" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, opts, _ot, _addl_opts ->
        assert :foo in opts

        {:ok, ""}
      end)

      assert {:ok, _} = MediaCollection.get_media_attributes_for_collection(@channel_url, [:foo])
    end

    test "passes additional args to runner" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        assert [{:output_filepath, filepath} | _] = addl_opts
        assert {:use_cookies, false} in addl_opts
        assert String.ends_with?(filepath, ".json")

        {:ok, ""}
      end)

      assert {:ok, _} = MediaCollection.get_media_attributes_for_collection(@channel_url)
    end

    test "supports an optional file_listener_handler that gets passed a filename" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, ""}
      end)

      current_self = self()

      handler = fn filename ->
        send(current_self, {:handler, filename})
      end

      assert {:ok, _} =
               MediaCollection.get_media_attributes_for_collection(@channel_url, [], file_listener_handler: handler)

      assert_receive {:handler, filename}
      assert String.ends_with?(filename, ".json")
    end

    test "deletes the generated tmpfile after the run" do
      test_pid = self()

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        send(test_pid, {:tmpfile, filepath, File.exists?(filepath)})

        {:ok, ""}
      end)

      assert {:ok, _} = MediaCollection.get_media_attributes_for_collection(@channel_url)

      assert_receive {:tmpfile, filepath, true}
      refute File.exists?(filepath)
      refute File.dir?(Path.dirname(filepath))
    end

    test "deletes the generated tmpfile when the run fails" do
      test_pid = self()

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        filepath = Keyword.get(addl_opts, :output_filepath)
        send(test_pid, {:tmpfile, filepath, File.exists?(filepath)})

        {:error, "Big issue", 1}
      end)

      assert {:error, "Big issue", 1} = MediaCollection.get_media_attributes_for_collection(@channel_url)

      assert_receive {:tmpfile, filepath, true}
      refute File.exists?(filepath)
    end

    test "leaves the tmpfile in place when a file_listener_handler is installed" do
      test_pid = self()

      handler = fn filepath -> send(test_pid, {:listener_filepath, filepath}) end

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, ""}
      end)

      assert {:ok, _} =
               MediaCollection.get_media_attributes_for_collection(@channel_url, [], file_listener_handler: handler)

      assert_receive {:listener_filepath, filepath}
      # Ownership transferred to the listener installer, so this method must not remove it
      assert File.exists?(filepath)

      FilesystemUtils.cleanup_metadata_tmpfile(filepath)
    end

    test "does not delete a caller-supplied output_filepath" do
      tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)
      caller_file = Path.join([tmpfile_directory, "caller_owned.json"])
      FilesystemUtils.write_p!(caller_file, "")

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, addl_opts ->
        assert Keyword.get(addl_opts, :output_filepath) == caller_file

        {:ok, ""}
      end)

      assert {:ok, _} =
               MediaCollection.get_media_attributes_for_collection(@channel_url, [], output_filepath: caller_file)

      assert File.exists?(caller_file)

      File.rm!(caller_file)
    end

    test "gracefully handles partially failed responses" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes_for_collection, _opts, _ot, _addl_opts ->
        {:ok, "INVALID\n\n" <> source_attributes_return_fixture() <> "\nINVALID\n"}
      end)

      assert {:ok, [%Media{media_id: "video1"}, %Media{media_id: "video2"}, %Media{media_id: "video3"}]} =
               MediaCollection.get_media_attributes_for_collection(@channel_url)
    end
  end

  describe "get_source_details/1" do
    test "returns a map with data on success" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl_opts ->
        Phoenix.json_library().encode(%{
          channel: "PinchflatTestChannel",
          channel_id: "UCQH2",
          playlist_id: "PLQH2",
          playlist_title: "PinchflatTestChannel - Videos"
        })
      end)

      assert {:ok, res} = MediaCollection.get_source_details(@channel_url)

      assert %{
               channel_id: "UCQH2",
               channel_name: "PinchflatTestChannel",
               playlist_id: "PLQH2",
               playlist_name: "PinchflatTestChannel - Videos"
             } = res
    end

    test "passes the expected args to the runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_details, opts, ot, _addl_opts ->
        assert opts == [:simulate, :skip_download, :ignore_no_formats_error, playlist_end: 1]
        assert ot == "%(.{channel,channel_id,playlist_id,playlist_title,filename})j"

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_details(@channel_url)
    end

    test "passes custom args to the runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_details, opts, _ot, _addl_opts ->
        assert {:foo, :bar} in opts

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_details(@channel_url, foo: :bar)
    end

    test "passes additional args to the runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_details, _opts, _ot, addl_opts ->
        assert {:use_cookies, true} in addl_opts

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_details(@channel_url, [], use_cookies: true)
    end

    test "returns an error if the runner returns an error" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl_opts -> {:error, "Big issue", 1} end)

      assert {:error, "Big issue", 1} = MediaCollection.get_source_details(@channel_url)
    end

    test "returns an error if the output is not JSON" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl_opts -> {:ok, "Not JSON"} end)

      assert {:error, "Error decoding JSON response"} = MediaCollection.get_source_details(@channel_url)
    end
  end

  describe "get_source_metadata/1" do
    test "returns a map with data on success" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        Phoenix.json_library().encode(%{channel: "PinchflatTestChannel"})
      end)

      assert {:ok, res} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 0)

      assert %{"channel" => "PinchflatTestChannel"} = res
    end

    test "passes the expected args to the backend runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_metadata, opts, ot, _addl_opts ->
        assert opts == [:skip_download, playlist_items: 0]
        assert ot == "playlist:%()j"

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 0)
    end

    test "passes additional args to the runner" do
      expect(YtDlpRunnerMock, :run, fn @channel_url, :get_source_metadata, _opts, _ot, addl_opts ->
        assert {:use_cookies, true} in addl_opts

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_metadata(@channel_url, [playlist_items: 0], use_cookies: true)
    end

    test "passes custom args to the runner" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, opts, _ot, _addl_opts ->
        assert opts == [:skip_download, playlist_items: 1, real_opt: :yup]

        {:ok, "{}"}
      end)

      assert {:ok, _} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 1, real_opt: :yup)
    end

    test "blows up if you pass addl opts but don't pass playlist items" do
      assert_raise KeyError, fn ->
        MediaCollection.get_source_metadata(@channel_url, real_opt: :yup)
      end
    end

    test "returns an error if the runner returns an error" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts ->
        {:error, "Big issue", 1}
      end)

      assert {:error, "Big issue", 1} = MediaCollection.get_source_metadata(@channel_url, playlist_items: 0)
    end

    test "returns an error if the output is not JSON" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_metadata, _opts, _ot, _addl_opts -> {:ok, "Not JSON"} end)

      assert {:error, "Error decoding JSON response"} =
               MediaCollection.get_source_metadata(@channel_url, playlist_items: 0)
    end
  end
end
