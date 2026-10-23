defmodule Pinchflat.Media.SearchIndexOptimizationWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.MediaItemsSearchIndex
  alias Pinchflat.Media.SearchIndexOptimizationWorker
  alias Pinchflat.Repo

  describe "optimize/0" do
    test "returns :ok" do
      media_item_fixture(title: "optimizable title")

      assert MediaItemsSearchIndex.optimize() == :ok
    end

    test "search still matches indexed rows after optimizing" do
      media_item_fixture(title: "uniquely matchable title")

      MediaItemsSearchIndex.optimize()

      sql = "SELECT rowid FROM media_items_search_index WHERE media_items_search_index MATCH ?"
      %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, ["uniquely matchable title"])

      assert length(rows) == 1
    end
  end

  describe "perform/1" do
    test "returns :ok" do
      media_item_fixture(title: "churned title")

      assert perform_job(SearchIndexOptimizationWorker, %{}) == :ok
    end
  end

  describe "optimize/0 on a churned index" do
    test "merges the churned index into a single segment and keeps the surviving rows searchable" do
      source = source_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # A wide spread of distinct titles/descriptions gives FTS5 plenty of index
      # segments to fragment once these rows get churned.
      rows =
        for i <- 1..500 do
          marker = if i > 400, do: "keptmarker", else: "droppedmarker"

          %{
            media_id: "churn-#{String.pad_leading(to_string(i), 4, "0")}",
            source_id: source.id,
            title: "churn title #{i} #{marker}",
            description: "churn description #{i} filler text",
            original_url: "https://example.com/churn/#{i}",
            inserted_at: now,
            updated_at: now
          }
        end

      assert {500, nil} = Repo.insert_all(MediaItem, rows)

      # Churn the index the way retention culling and metadata refreshes do:
      # deletes leave tombstones behind and updates append new segments instead
      # of rewriting the existing ones. Media ids are zero padded, so the
      # lexicographic comparison culls the first 400 of the 500 rows.
      assert %{num_rows: 400} =
               Ecto.Adapters.SQL.query!(
                 Repo,
                 "DELETE FROM media_items WHERE media_id LIKE 'churn-%' AND media_id <= 'churn-0400'",
                 []
               )

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE media_items SET title = 'rev2 ' || title WHERE media_id LIKE 'churn-%'",
        []
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE media_items SET title = 'rev3 ' || title WHERE media_id LIKE 'churn-%'",
        []
      )

      before = search_index_stats()

      assert before.segments > 1,
             "expected the churned index to be split into several segments, got #{before.segments}"

      assert MediaItemsSearchIndex.optimize() == :ok

      after_optimize = search_index_stats()

      # This is what the weekly job is for: the churned segments are merged back
      # into a single one, and the space they held is handed back to the
      # freelist instead of trailing along in the index.
      assert after_optimize.segments == 1
      assert after_optimize.blobs < before.blobs
      assert after_optimize.bytes < before.bytes

      # Compacting the index must not change what it holds: the surviving rows
      # are still searchable and the culled ones stay gone.
      assert match_count("keptmarker") == 100
      assert match_count("droppedmarker") == 0
      assert match_count("churn title 401") == 1

      # A second pass is idempotent: there is nothing left to merge.
      assert MediaItemsSearchIndex.optimize() == :ok
      assert search_index_stats() == after_optimize
    end
  end

  # FTS5 stores one row per index segment in the %_idx shadow table (one
  # distinct segid per segment), and the segment payloads in %_data, whose row
  # count is the `SELECT count(*) FROM media_items_search_index_data` of the
  # issue. dbstat reports the live b-tree pages those payloads occupy; the
  # freed ones end up on the freelist rather than shrinking the file.
  defp search_index_stats do
    %{rows: [[segments]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(DISTINCT segid) FROM media_items_search_index_idx",
        []
      )

    %{rows: [[blobs]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM media_items_search_index_data", [])

    %{rows: [[bytes]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT coalesce(sum(pgsize), 0) FROM dbstat WHERE name = 'media_items_search_index_data'",
        []
      )

    %{segments: segments, blobs: blobs, bytes: bytes}
  end

  defp match_count(term) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM media_items_search_index WHERE media_items_search_index MATCH ?",
        [term]
      )

    count
  end
end
