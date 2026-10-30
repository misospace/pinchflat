defmodule Pinchflat.Downloading.MediaQualityUpgradeWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Downloading.MediaQualityUpgradeWorker

  describe "perform/1" do
    test "kicks off a task for redownloadable media items" do
      media_profile = media_profile_fixture(%{redownload_delay_days: 4})
      source = source_fixture(%{media_profile_id: media_profile.id, inserted_at: now_minus(10, :days)})

      media_item =
        media_item_fixture(%{
          source_id: source.id,
          uploaded_at: now_minus(6, :days),
          media_downloaded_at: now_minus(5, :days)
        })

      perform_job(MediaQualityUpgradeWorker, %{})

      assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{id: media_item.id, quality_upgrade?: true})
    end

    test "does not kickoff a task for non-redownloadable media items" do
      media_profile = media_profile_fixture(%{redownload_delay_days: 4})
      source = source_fixture(%{media_profile_id: media_profile.id, inserted_at: now_minus(10, :days)})

      _media_item =
        media_item_fixture(%{
          source_id: source.id,
          uploaded_at: now_minus(6, :days),
          media_downloaded_at: now_minus(1, :day)
        })

      perform_job(MediaQualityUpgradeWorker, %{})

      assert [] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "does not kickoff a task for media items of a disabled source" do
      media_profile = media_profile_fixture(%{redownload_delay_days: 4})

      disabled_source =
        source_fixture(%{media_profile_id: media_profile.id, enabled: false, inserted_at: now_minus(10, :days)})

      _media_item =
        media_item_fixture(%{
          source_id: disabled_source.id,
          uploaded_at: now_minus(6, :days),
          media_downloaded_at: now_minus(5, :days)
        })

      perform_job(MediaQualityUpgradeWorker, %{})

      assert [] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "kicks off a task only for the enabled sources media items" do
      media_profile = media_profile_fixture(%{redownload_delay_days: 4})
      enabled_source = source_fixture(%{media_profile_id: media_profile.id, inserted_at: now_minus(10, :days)})
      disabled_source = source_fixture(%{media_profile_id: media_profile.id, enabled: false})

      media_item =
        media_item_fixture(%{
          source_id: enabled_source.id,
          uploaded_at: now_minus(6, :days),
          media_downloaded_at: now_minus(5, :days)
        })

      _disabled_media_item =
        media_item_fixture(%{
          source_id: disabled_source.id,
          uploaded_at: now_minus(6, :days),
          media_downloaded_at: now_minus(5, :days)
        })

      perform_job(MediaQualityUpgradeWorker, %{})

      assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{id: media_item.id, quality_upgrade?: true})
      assert length(all_enqueued(worker: MediaDownloadWorker)) == 1
    end
  end
end
