defmodule Pinchflat.Media.SearchIndexOptimizationWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

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
end
