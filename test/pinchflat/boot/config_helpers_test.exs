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

      log =
        capture_log(fn ->
          assert ConfigHelpers.safe_int_env("PINCHFLAT_TEST_BAD_INT", 10) == 10
        end)

      assert log =~ "[warning]"
      assert log =~ "PINCHFLAT_TEST_BAD_INT"
      assert log =~ "not-a-number"
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
end
