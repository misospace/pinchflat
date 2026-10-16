defmodule Pinchflat.SlowIndexing.FileFollowerServer do
  @moduledoc """
  A GenServer that watches a file for new lines and processes them as they come in.
  This is useful for tailing log files and other similar tasks. If there's no activity
  for a certain amount of time, the server will stop itself.
  """
  use GenServer

  require Logger

  @poll_interval_ms Application.compile_env(:pinchflat, :file_watcher_poll_interval)
  @activity_timeout_ms 600_000
  @default_stop_timeout_ms 5_000
  @default_kill_grace_ms 5_000

  # Client API
  @doc """
  Starts the file follower server

  Returns {:ok, pid} or {:error, reason}
  """
  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end

  @doc """
  Starts the file watcher for a given filepath and handler function.

  Returns :ok
  """
  def watch_file(process, filepath, handler) do
    GenServer.cast(process, {:watch_file, filepath, handler})
  end

  @doc """
  Stops the file watcher and closes the file.

  Returns :ok
  """
  def stop(process) do
    GenServer.cast(process, :stop)
  end

  @doc """
  Stops the file watcher and waits until the server process has actually shut down.

  The stop request rides the server's mailbox (same FIFO as `watch_file/3`), so
  every cast queued before it is handled before the process exits. Callers that
  delete the followed file MUST use this instead of `stop/1` — a bare cast returns
  immediately and the unlink could race the follower's shutdown, or even its file open.

  Returns `:ok` only once the process is known to be down, which is the boundary a
  caller needs before unlinking the followed file:

  - already dead: `:ok` at once (its descriptor died with it)
  - graceful stop within `:timeout`: `:ok`
  - still alive after `:timeout`: the process is killed (untrappable, so its descriptor
    closes with it) and given `:kill_grace_ms` to die; `:ok` if it does
  - alive even after that (wedged in a system call the VM can't interrupt):
    `{:error, :follower_unresponsive}`, so the caller leaves the file in place rather
    than unlinking a descriptor that is still open

  Options:
  - `:timeout`: how long to wait for the graceful stop before killing (default 5000)
  - `:kill_grace_ms`: how long to wait for the kill to land (default 5000)

  Returns :ok | {:error, :follower_unresponsive}
  """
  def stop_and_wait(process, opts \\ []) do
    if Process.alive?(process) do
      ref = Process.monitor(process)

      GenServer.cast(process, :stop)

      await_graceful_shutdown(
        process,
        ref,
        Keyword.get(opts, :timeout, @default_stop_timeout_ms),
        Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms)
      )
    else
      :ok
    end
  end

  defp await_graceful_shutdown(process, ref, timeout, kill_grace_ms) do
    receive do
      {:DOWN, ^ref, :process, ^process, _reason} -> :ok
    after
      timeout ->
        Logger.warning("File follower did not shut down within #{timeout}ms; killing it")

        # Unlink first: a kill of a linked process takes the caller down with it, and
        # by this point the caller is past the stage where a follower crash should fail
        # its job. The kill itself still closes the follower's file descriptor.
        Process.unlink(process)
        Process.exit(process, :kill)

        await_kill(process, ref, kill_grace_ms)
    end
  end

  defp await_kill(process, ref, kill_grace_ms) do
    receive do
      {:DOWN, ^ref, :process, ^process, _reason} -> :ok
    after
      kill_grace_ms ->
        Process.demonitor(ref, [:flush])

        Logger.error("File follower survived a forced kill after #{kill_grace_ms}ms; it still holds its file open")

        {:error, :follower_unresponsive}
    end
  end

  # Server Callbacks
  @impl true
  def init(_opts) do
    # Start with a blank state because, based on the common calling
    # pattern for this module, we'll need a reference to the server's
    # PID before we start watching any files so we can later stop the
    # server gracefully.
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:watch_file, filepath, handler}, old_state) do
    case :file.open(filepath, [:raw, :read_ahead, :binary]) do
      {:ok, io_device} ->
        state = %{
          io_device: io_device,
          last_activity: DateTime.utc_now(),
          handler: handler
        }

        Process.send(self(), :read_new_lines, [])

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to open file for watching: #{filepath} (#{reason})")

        {:stop, :normal, old_state}
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    Logger.debug("Gracefully stopping file follower")
    :file.close(state.io_device)

    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:read_new_lines, state) do
    last_activity = state.last_activity

    # If there's no new lines written for a certain amount of time, stop the server
    if DateTime.diff(DateTime.utc_now(), last_activity, :millisecond) > @activity_timeout_ms do
      Logger.debug("No activity for #{@activity_timeout_ms}ms. Requesting stop.")
      stop(self())

      {:noreply, state}
    else
      attempt_process_new_lines(state)
    end
  end

  defp attempt_process_new_lines(state) do
    io_device = state.io_device

    # This reads one line at a time. If a line is found, it
    # will be passed to the handler, we'll note the time of
    # the last activity, and then we'll immediately call this
    # again to read the next line.
    #
    # If there are no lines, it waits for the poll interval
    # before trying again.
    case :file.read_line(io_device) do
      {:ok, line} ->
        state.handler.(line)

        Process.send(self(), :read_new_lines, [])

        {:noreply, %{state | last_activity: DateTime.utc_now()}}

      :eof ->
        Logger.debug("Current batch of media processed. Will check again in #{@poll_interval_ms}ms")
        Process.send_after(self(), :read_new_lines, @poll_interval_ms)

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Error reading file: #{reason}")
        stop(self())

        {:noreply, state}
    end
  end
end
