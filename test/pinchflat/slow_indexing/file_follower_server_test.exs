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

    test "kills a watcher that refuses to stop and returns once it is dead", %{tmpfile: tmpfile} do
      {:ok, pid} = FileFollowerServer.start_link()
      on_exit(fn -> Process.exit(pid, :kill) end)

      File.write!(tmpfile, "line1\n")

      # A long handler keeps the server busy, so it can't acknowledge the stop request
      # in time and has to be killed instead. Waiting for the handler to actually start
      # (instead of sleeping a guessed interval) makes the stop reliably lose that race,
      # and the sleep sits far above the bound asserted below: a graceful stop would have
      # to wait it out, so this test can't pass without exercising the kill path.
      parent = self()

      handler = fn _line ->
        send(parent, :handling)
        :timer.sleep(3_000)
      end

      FileFollowerServer.watch_file(pid, tmpfile, handler)
      assert_receive :handling, 1_000

      started_at = System.monotonic_time(:millisecond)
      assert :ok = FileFollowerServer.stop_and_wait(pid, timeout: 50)
      assert System.monotonic_time(:millisecond) - started_at < 1_000

      # A forced kill still satisfies the caller's contract: the process is gone, so
      # its descriptor is closed and an unlink can't race it.
      assert Process.info(pid) == nil

      File.rm(tmpfile)
    end

    test "kills a suspended watcher rather than reporting an error", %{tmpfile: tmpfile} do
      {:ok, pid} = FileFollowerServer.start_link()

      # A suspended process runs none of its own code, so it never acknowledges the stop
      # request — the closest in-VM stand-in for a follower wedged in a long handler.
      # `exit/2` is delivered to it regardless (suspension blocks scheduling, not signal
      # delivery), which is why the kill escalation is a guarantee rather than a hope:
      # the only follower that could report `{:error, :follower_unresponsive}` is one
      # wedged in a system call the VM cannot interrupt at all.
      :erlang.suspend_process(pid)

      File.write!(tmpfile, "line1\n")
      FileFollowerServer.watch_file(pid, tmpfile, fn _line -> :noop end)

      assert :ok = FileFollowerServer.stop_and_wait(pid, timeout: 50, kill_grace_ms: 50)
      assert Process.info(pid) == nil

      File.rm(tmpfile)
    end
  end
end
