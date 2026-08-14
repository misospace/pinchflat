defmodule Pinchflat.Boot.PostBootStartupTasksTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.UpdateWorker
  alias Pinchflat.Boot.PostBootStartupTasks

  describe "update_yt_dlp" do
    test "does not enqueue an update job for the default stable policy" do
      assert [] = all_enqueued(worker: UpdateWorker)

      PostBootStartupTasks.init(%{})

      assert [] = all_enqueued(worker: UpdateWorker)
    end

    test "enqueues an update job for the pinned policy" do
      Settings.set(yt_dlp_pinned_version: "2024.01.01")
      Settings.set(yt_dlp_update_policy: "pinned")

      assert [] = all_enqueued(worker: UpdateWorker)

      PostBootStartupTasks.init(%{})

      assert [%Oban.Job{}] = all_enqueued(worker: UpdateWorker)
    end
  end
end
