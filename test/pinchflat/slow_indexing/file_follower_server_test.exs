defmodule Pinchflat.SlowIndexing.FileFollowerServerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.SlowIndexing.FileFollowerServer

  defmodule LogStore do
    @moduledoc false
    use Agent

    def start do
      Agent.start(fn -> [] end, name: __MODULE__)
    end

    def add(entry) do
      Agent.update(__MODULE__, fn logs -> [entry | logs] end)
    end

    def entries do
      Agent.get(__MODULE__, & &1)
    end
  end

  defmodule LogCollector do
    @moduledoc false

    def init(_config), do: {:ok, []}

    def log(event, _logs) do
      LogStore.add({event.level, event.msg})
      {:ok, []}
    end

    def terminate(_reason, _logs), do: :ok
  end

  setup do
    {:ok, pid} = FileFollowerServer.start_link()
    tmpfile = FilesystemUtils.generate_metadata_tmpfile(:txt)

    {:ok, %{pid: pid, tmpfile: tmpfile}}
  end

  describe "watch_file" do
    test "calls the handler for each existing line in the file", %{pid: pid, tmpfile: tmpfile} do
      File.write!(tmpfile, "line1\nline2")
      parent = self()

      handler = fn line -> send(parent, line) end
      FileFollowerServer.watch_file(pid, tmpfile, handler)

      assert_receive "line1\n"
      assert_receive "line2"
    end

    test "calls the handler for each new line in the file", %{pid: pid, tmpfile: tmpfile} do
      parent = self()
      file = File.open!(tmpfile, [:append])
      handler = fn line -> send(parent, line) end

      FileFollowerServer.watch_file(pid, tmpfile, handler)

      IO.binwrite(file, "line1\n")
      assert_receive "line1\n"
      IO.binwrite(file, "line2")
      assert_receive "line2"
    end

    test "stops the server with :normal when the file is missing", %{pid: pid, tmpfile: tmpfile} do
      {:ok, _} = LogStore.start()
      :logger.add_handler(:test_log_collector, LogCollector, %{})
      :logger.set_primary_config(:level, :debug)

      on_exit(fn ->
        :logger.set_primary_config(:level, :critical)
        :logger.remove_handler(:test_log_collector)
        Agent.stop(LogStore)
      end)

      File.rm!(tmpfile)
      ref = Process.monitor(pid)

      FileFollowerServer.watch_file(pid, tmpfile, fn _line -> :noop end)

      receive do
        {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      after
        1_000 -> flunk("expected the server to stop with :normal")
      end

      assert Enum.any?(LogStore.entries(), fn
               {:error, {:string, msg}} -> msg =~ "Failed to open file for watching: #{tmpfile}"
               _other -> false
             end)
    end
  end

  describe "stop" do
    test "stops the watcher", %{pid: pid, tmpfile: tmpfile} do
      handler = fn _line -> :noop end
      FileFollowerServer.watch_file(pid, tmpfile, handler)

      refute is_nil(Process.info(pid))
      FileFollowerServer.stop(pid)
      # Gotta wait for the server to stop async
      :timer.sleep(50)
      assert is_nil(Process.info(pid))
    end
  end

  describe "stop_and_wait" do
    test "returns only once the watcher has fully shut down", %{pid: pid, tmpfile: tmpfile} do
      handler = fn _line -> :noop end
      FileFollowerServer.watch_file(pid, tmpfile, handler)

      refute is_nil(Process.info(pid))
      assert :ok = FileFollowerServer.stop_and_wait(pid)

      # The monitor-based wait means the process is gone by the time the caller
      # gets back control, so its file descriptor is closed and a subsequent
      # unlink can never race the follower.
      assert Process.info(pid) == nil
    end

    test "returns immediately when the watcher is already dead", %{pid: pid} do
      # Unlink first: killing a linked process would take the test process down with it
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      started_at = System.monotonic_time(:millisecond)
      assert :ok = FileFollowerServer.stop_and_wait(pid)
      assert System.monotonic_time(:millisecond) - started_at < 1_000
    end

    test "returns :ok without hanging when the watcher refuses to stop", %{tmpfile: tmpfile} do
      {:ok, pid} = FileFollowerServer.start_link()
      on_exit(fn -> Process.exit(pid, :kill) end)

      File.write!(tmpfile, "line1\n")

      # A slow handler keeps the server busy, so it cannot acknowledge the
      # stop request before the timeout elapses.
      FileFollowerServer.watch_file(pid, tmpfile, fn _line -> :timer.sleep(300) end)
      :timer.sleep(20)

      started_at = System.monotonic_time(:millisecond)
      assert :ok = FileFollowerServer.stop_and_wait(pid, 50)
      assert System.monotonic_time(:millisecond) - started_at < 250

      File.rm(tmpfile)
    end
  end
end
