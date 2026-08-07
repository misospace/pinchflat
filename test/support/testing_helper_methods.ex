defmodule Pinchflat.TestingHelperMethods do
  @moduledoc false

  use ExUnit.CaseTemplate

  def now do
    DateTime.utc_now()
  end

  def now_plus(offset, unit) when unit in [:minute, :minutes] do
    DateTime.add(now(), offset, :minute)
  end

  def now_minus(offset, unit) when unit in [:minute, :minutes] do
    DateTime.add(now(), -offset, :minute)
  end

  def now_minus(offset, unit) when unit in [:day, :days] do
    DateTime.add(now(), -offset, :day)
  end

  def assert_changed(checker_fun, action_fn) do
    before_res = checker_fun.()
    action_fn.()
    after_res = checker_fun.()

    assert before_res != after_res
  end

  def assert_changed([from: from, to: to], checker_fun, action_fn) do
    before_res = checker_fun.()
    action_fn.()
    after_res = checker_fun.()

    assert before_res == from
    assert after_res == to
  end

  def render_metadata(metadata_name) do
    json_filepath =
      Path.join([
        File.cwd!(),
        "test",
        "support",
        "files",
        "#{metadata_name}.json"
      ])

    # The fixtures mirror real yt-dlp output, which emits ABSOLUTE paths. They were
    # captured on a checkout at /app, so reading them verbatim only works when the
    # repo happens to live there. Rebase onto the current checkout instead.
    json_filepath
    |> File.read!()
    |> String.replace("/app/test/", Path.join(File.cwd!(), "test") <> "/")
  end

  def render_parsed_metadata(metadata_name) do
    metadata_name
    |> render_metadata()
    |> Phoenix.json_library().decode!()
  end

  def create_platform_directories do
    File.mkdir_p!(Application.get_env(:pinchflat, :media_directory))
    File.mkdir_p!(Application.get_env(:pinchflat, :metadata_directory))
    File.mkdir_p!(Application.get_env(:pinchflat, :extras_directory))
    File.mkdir_p!(Application.get_env(:pinchflat, :tmpfile_directory))
  end
end
