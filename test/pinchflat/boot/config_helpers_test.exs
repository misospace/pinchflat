defmodule Pinchflat.Boot.ConfigHelpersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pinchflat.Boot.ConfigHelpers

  @env_vars ["PINCHFLAT_TEST_SAFE_INT", "PINCHFLAT_TEST_EMPTY_INT", "PINCHFLAT_TEST_BAD_INT"]

  setup do
    # Snapshot the variables so each test restores them afterwards.
    previous = Map.new(@env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn {name, value} ->
        if is_nil(value) do
          System.delete_env(name)
        else
          System.put_env(name, value)
        end
      end)
    end)

    :ok
  end

  describe "safe_int_env/2" do
    test "returns the parsed integer when the env var is a valid integer" do
      System.put_env("PINCHFLAT_TEST_SAFE_INT", "42")

      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_SAFE_INT", 10) == 42
    end

    test "returns the default when the env var is unset" do
      System.delete_env("PINCHFLAT_TEST_SAFE_INT")

      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_SAFE_INT", 10) == 10
    end

    test "returns the default when the env var is an empty string" do
      System.put_env("PINCHFLAT_TEST_EMPTY_INT", "")

      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_EMPTY_INT", 10) == 10
    end

    test "returns the default when the env var is a whitespace string" do
      System.put_env("PINCHFLAT_TEST_EMPTY_INT", " ")

      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_EMPTY_INT", 10) == 10
    end

    test "returns the default when the env var is not parseable as an integer" do
      System.put_env("PINCHFLAT_TEST_BAD_INT", "not-a-number")

      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_BAD_INT", 10) == 10
    end

    test "returns the default when the env var has trailing non-numeric characters" do
      System.put_env("PINCHFLAT_TEST_BAD_INT", "12abc")

      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_BAD_INT", 10) == 10
    end

    test "returns the default when the env var is a float" do
      System.put_env("PINCHFLAT_TEST_BAD_INT", "1.5")

      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_BAD_INT", 10) == 10
    end

    test "accepts zero and negative integers" do
      System.put_env("PINCHFLAT_TEST_SAFE_INT", "0")
      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_SAFE_INT", 10) == 0

      System.put_env("PINCHFLAT_TEST_SAFE_INT", "-7")
      assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_SAFE_INT", 10) == -7
    end

    test "requires a binary name and integer default" do
      assert_raise FunctionClauseError, fn -> ConfigHelpers.safe_int_env(:not_a_string, 10) end
      assert_raise FunctionClauseError, fn -> ConfigHelpers.safe_int_env("VAR", "10") end
    end

    test "logs a warning naming the variable, rejected value, and default when the env var is set but unparseable" do
      System.put_env("PINCHFLAT_TEST_BAD_INT", "not-a-number")

      previous_log_level = Logger.level()

      log =
        try do
          Logger.configure(level: :debug)
          capture_log(fn -> assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_BAD_INT", 10) == 10 end)
        after
          Logger.configure(level: previous_log_level)
        end

      assert log =~ "[warning]"
      assert log =~ "PINCHFLAT_TEST_BAD_INT"
      assert log =~ "not-a-number"
      assert log =~ "using default"
      assert log =~ "10"
    end

    test "stays silent when the env var is unset" do
      System.delete_env("PINCHFLAT_TEST_BAD_INT")

      log =
        capture_log(fn ->
          assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_BAD_INT", 10) == 10
        end)

      refute log =~ "PINCHFLAT_TEST_BAD_INT"
      refute log =~ "using default"
    end

    test "stays silent when the env var parses cleanly" do
      System.put_env("PINCHFLAT_TEST_SAFE_INT", "42")

      log =
        capture_log(fn ->
          assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_SAFE_INT", 10) == 42
        end)

      refute log =~ "PINCHFLAT_TEST_SAFE_INT"
      refute log =~ "using default"
    end
  end

  describe "resolve_secret_key_base/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "pinchflat-secret-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, path: Path.join(dir, ".secret_key_base")}
    end

    test "persists a fresh secret of at least 64 bytes when no file exists", %{path: path} do
      secret = ConfigHelpers.resolve_secret_key_base(nil, path)

      assert byte_size(secret) >= 64
      assert File.read!(path) == secret
    end

    test "generates distinct secrets on repeated fresh installs", %{path: path} do
      first = ConfigHelpers.resolve_secret_key_base(nil, path)
      File.rm!(path)
      second = ConfigHelpers.resolve_secret_key_base(nil, path)

      assert first != second
    end

    test "returns the persisted secret unchanged when it is at least 64 bytes", %{path: path} do
      existing = String.duplicate("a", 64)
      File.write!(path, existing)

      assert ConfigHelpers.resolve_secret_key_base(nil, path) == existing
      assert File.read!(path) == existing
    end

    test "regenerates and rewrites an existing short persisted secret", %{path: path} do
      # 43 characters: the value produced by the pre-1.4.5 32-byte generator.
      short = String.duplicate("b", 43)
      File.write!(path, short)

      previous_log_level = Logger.level()

      log =
        try do
          Logger.configure(level: :debug)
          capture_log(fn -> ConfigHelpers.resolve_secret_key_base(nil, path) end)
        after
          Logger.configure(level: previous_log_level)
        end

      assert log =~ "Regenerating"
      secret = File.read!(path)
      assert byte_size(secret) >= 64
      refute secret == short
      assert ConfigHelpers.resolve_secret_key_base(nil, path) == secret
    end

    test "trims a trailing newline from a valid persisted secret", %{path: path} do
      existing = String.duplicate("g", 64)
      File.write!(path, existing <> "\n")

      assert ConfigHelpers.resolve_secret_key_base(nil, path) == existing
    end

    test "returns an explicitly supplied env secret of at least 64 bytes as-is", %{path: path} do
      supplied = String.duplicate("c", 80)

      assert ConfigHelpers.resolve_secret_key_base(supplied, path) == supplied
      refute File.exists?(path)
    end

    test "falls back to the persisted secret when the env secret is too short", %{path: path} do
      existing = String.duplicate("d", 64)
      File.write!(path, existing)

      previous_log_level = Logger.level()

      log =
        try do
          Logger.configure(level: :debug)

          capture_log(fn ->
            assert ConfigHelpers.resolve_secret_key_base(String.duplicate("e", 43), path) == existing
          end)
        after
          Logger.configure(level: previous_log_level)
        end

      assert log =~ "SECRET_KEY_BASE is 43 bytes"
      assert File.read!(path) == existing
    end

    test "generates a persisted secret when the env secret is too short and no file exists", %{path: path} do
      ConfigHelpers.resolve_secret_key_base(String.duplicate("f", 43), path)

      secret = File.read!(path)
      assert byte_size(secret) >= 64
      assert ConfigHelpers.resolve_secret_key_base(String.duplicate("f", 43), path) == secret
    end

    test "is stable across restarts: a second call returns the same secret", %{path: path} do
      first = ConfigHelpers.resolve_secret_key_base(nil, path)
      second = ConfigHelpers.resolve_secret_key_base(nil, path)

      assert first == second
    end
  end
end
