defmodule Pinchflat.YtDlp.UpdateManagerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.UpdateManager

  describe "policies/0" do
    test "returns every supported policy" do
      assert UpdateManager.policies() == ~w(stable nightly nightly_frozen nightly_until_stable pinned)
    end
  end

  describe "humanize_policy/1" do
    test "returns a human-friendly label for each policy" do
      assert UpdateManager.humanize_policy("stable") == "Stable"
      assert UpdateManager.humanize_policy("nightly") == "Nightly"
      assert UpdateManager.humanize_policy("nightly_frozen") == "Nightly, frozen"
      assert UpdateManager.humanize_policy("nightly_until_stable") == "Nightly until stable"
      assert UpdateManager.humanize_policy("pinned") == "Pinned"
    end

    test "falls back to Stable for unknown values" do
      assert UpdateManager.humanize_policy("what") == "Stable"
      assert UpdateManager.humanize_policy(nil) == "Stable"
    end
  end

  describe "run_scheduled_update/0 when the update fails" do
    test "propagates the runner error so Oban can record and retry it" do
      Settings.set(yt_dlp_update_policy: "nightly")
      Settings.set(yt_dlp_version: "2025.01.01")
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:error, "no internet"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:error, "no binary"} end)

      assert {:error, {:update_failed, "nightly", "no internet"}} =
               UpdateManager.run_scheduled_update()

      # The recorded version should not have been clobbered with the same value
      # `version()` failed to read.
      assert {:ok, "2025.01.01"} = Settings.get(:yt_dlp_version)
    end

    test "still returns :ok for legitimate no-op behaviour (nightly_frozen with no baseline)" do
      Settings.set(yt_dlp_update_policy: "nightly_frozen")
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.01.01"} end)

      assert :ok = UpdateManager.run_scheduled_update()
    end
  end

  describe "apply_policy/0 when the version can't be read back" do
    test "does not record a nightly baseline it doesn't know" do
      Settings.set(yt_dlp_update_policy: "nightly_frozen")
      Settings.set(yt_dlp_nightly_baseline: nil)
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:ok, ""} end)
      # once for the baseline capture, once for the version refresh
      expect(YtDlpRunnerMock, :version, 2, fn -> {:error, "no binary"} end)

      assert :ok = UpdateManager.apply_policy()
      assert {:ok, nil} = Settings.get(:yt_dlp_nightly_baseline)
    end

    test "propagates the runner error when applying nightly_frozen fails" do
      Settings.set(yt_dlp_update_policy: "nightly_frozen")
      Settings.set(yt_dlp_nightly_baseline: nil)
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:error, "no internet"} end)
      # `refresh_installed_version/0` still calls `version/0` after a failed
      # jump so the saved `yt_dlp_version` can be corrected from drift; stub
      # it with a read failure to mirror the `run_scheduled_update` failing case.
      expect(YtDlpRunnerMock, :version, fn -> {:error, "no binary"} end)

      assert {:error, {:update_failed, "nightly", "no internet"}} =
               UpdateManager.apply_policy()

      # Baseline must stay nil - a failed jump leaves the old binary in place
      # and we must not silently pin the held build to whatever was already
      # installed.
      assert {:ok, nil} = Settings.get(:yt_dlp_nightly_baseline)
    end

    test "does not replace an existing baseline when applying nightly_until_stable fails" do
      # An existing baseline reflects the build we _intend_ to be on. A failed
      # re-jump must leave it intact; otherwise the next frozen reassertion
      # would target the old installed version, not the held nightly.
      Settings.set(yt_dlp_update_policy: "nightly_until_stable")
      Settings.set(yt_dlp_nightly_baseline: "2025.06.28.123456")
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:error, "no internet"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.06.27"} end)

      assert {:error, {:update_failed, "nightly", "no internet"}} =
               UpdateManager.apply_policy()

      assert {:ok, "2025.06.28.123456"} = Settings.get(:yt_dlp_nightly_baseline)
    end

    test "records the fresh baseline when the jump to nightly succeeds" do
      Settings.set(yt_dlp_update_policy: "nightly_until_stable")
      Settings.set(yt_dlp_nightly_baseline: nil)
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:ok, ""} end)
      # once for the baseline capture, once for the version refresh
      expect(YtDlpRunnerMock, :version, 2, fn -> {:ok, "2025.06.28.123456"} end)

      assert :ok = UpdateManager.apply_policy()

      assert {:ok, "2025.06.28.123456"} = Settings.get(:yt_dlp_nightly_baseline)
    end
  end

  describe "run_scheduled_update/0 with the nightly_until_stable policy when reverting fails" do
    test "keeps the held policy and baseline intact when the stable install fails" do
      Settings.set(yt_dlp_update_policy: "nightly_until_stable")
      Settings.set(yt_dlp_nightly_baseline: "2025.06.28.123456")
      stub_latest_stable("2025.07.01")
      expect(YtDlpRunnerMock, :update, fn "2025.07.01" -> {:error, "no internet"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.06.28.123456"} end)

      assert {:error, {:update_failed, "2025.07.01", "no internet"}} =
               UpdateManager.run_scheduled_update()

      # The policy and baseline must not have transitioned: the policy is
      # nominally `nightly_until_stable` (so a later cron tick will retry the
      # stable install), and the held nightly build is still recorded so the
      # next successful revert can clear it.
      assert {:ok, "nightly_until_stable"} = Settings.get(:yt_dlp_update_policy)
      assert {:ok, "2025.06.28.123456"} = Settings.get(:yt_dlp_nightly_baseline)
    end

    test "commits the transition only after the stable install succeeds" do
      Settings.set(yt_dlp_update_policy: "nightly_until_stable")
      Settings.set(yt_dlp_nightly_baseline: "2025.06.28.123456")
      stub_latest_stable("2025.07.01")
      expect(YtDlpRunnerMock, :update, fn "2025.07.01" -> {:ok, ""} end)
      expect(YtDlpRunnerMock, :version, fn -> {:ok, "2025.07.01"} end)

      assert :ok = UpdateManager.run_scheduled_update()

      assert {:ok, "stable"} = Settings.get(:yt_dlp_update_policy)
      assert {:ok, nil} = Settings.get(:yt_dlp_nightly_baseline)
    end
  end
end
