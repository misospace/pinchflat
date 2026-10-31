defmodule Pinchflat.Lifecycle.Notifications.CommandRunnerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Lifecycle.Notifications.CommandRunner, as: Runner

  import ExUnit.CaptureLog

  @original_executable Application.compile_env(:pinchflat, :apprise_executable)
  @credentialed_endpoint "json://audit-user:synthetic-password@localhost/hook"

  setup do
    on_exit(&reset_executable/0)
  end

  describe "run/2" do
    test "returns :ok when the command succeeds" do
      assert {:ok, _} = Runner.run("server_1", [])
    end

    test "includes the servers as the first argument" do
      assert {:ok, output} = Runner.run(["server_1", "server_2"], [])

      assert String.contains?(output, "server_1 server_2")
    end

    test "lets you pass a single server as a string" do
      assert {:ok, output} = Runner.run("server_1", [])

      assert String.contains?(output, "server_1")
    end

    test "passes all arguments to the command" do
      assert {:ok, output} = Runner.run("server_1", ["--dry-run"])

      assert String.contains?(output, "--dry-run")
    end

    test "returns the output when the command fails" do
      wrap_executable("#{File.cwd!()}/test/support/scripts/yt-dlp-mocks/1_exit_code.sh", fn ->
        assert {:error, ""} = Runner.run("server_1", [])
      end)
    end

    test "returns a relevant error if no servers are provided" do
      assert {:error, :no_servers} = Runner.run(nil, [])
      assert {:error, :no_servers} = Runner.run("", [])
      assert {:error, :no_servers} = Runner.run([], [])
    end
  end

  describe "run/2 credential redaction" do
    setup do
      # The test env logger level suppresses everything below :critical,
      # so it needs to be loosened for log output to be capturable
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)
    end

    test "does not log the endpoint or its credentials on success" do
      log =
        capture_log([level: :debug], fn ->
          assert {:ok, output} = Runner.run(@credentialed_endpoint, [])

          # The test executable echoes its arguments, proving the endpoint
          # still reached the process unchanged
          assert String.contains?(output, @credentialed_endpoint)
        end)

      refute log =~ @credentialed_endpoint
      refute log =~ "synthetic-password"
      assert log =~ "[suppressed]"
    end

    test "does not log the endpoint or its credentials when given a list of endpoints" do
      log =
        capture_log([level: :debug], fn ->
          assert {:ok, output} = Runner.run(["server_1", @credentialed_endpoint], [])

          assert String.contains?(output, @credentialed_endpoint)
        end)

      refute log =~ @credentialed_endpoint
      refute log =~ "synthetic-password"
    end

    test "does not log the endpoint or its credentials on a non-zero exit" do
      wrap_executable("#{File.cwd!()}/test/support/scripts/yt-dlp-mocks/1_exit_code.sh", fn ->
        log =
          capture_log([level: :debug], fn ->
            assert {:error, _} = Runner.run(@credentialed_endpoint, [])
          end)

        refute log =~ @credentialed_endpoint
        refute log =~ "synthetic-password"
      end)
    end

    test "does not let echoed child-process output reintroduce credentials into logs or the error" do
      wrap_executable("#{File.cwd!()}/test/support/scripts/yt-dlp-mocks/repeater_exit_1.sh", fn ->
        log =
          capture_log([level: :debug], fn ->
            assert {:error, error_output} = Runner.run(@credentialed_endpoint, [])

            # The executable echoes its arguments before failing, so the
            # returned error must be scrubbed before upstream callers log it
            refute String.contains?(error_output, @credentialed_endpoint)
            assert String.contains?(error_output, "[redacted]")
          end)

        refute log =~ @credentialed_endpoint
        refute log =~ "synthetic-password"
      end)
    end
  end

  describe "version/0" do
    test "adds the version arg" do
      assert {:ok, output} = Runner.version()

      assert String.contains?(output, "--version")
    end
  end

  defp wrap_executable(new_executable, fun) do
    Application.put_env(:pinchflat, :apprise_executable, new_executable)
    fun.()
    reset_executable()
  end

  def reset_executable do
    Application.put_env(:pinchflat, :apprise_executable, @original_executable)
  end
end
