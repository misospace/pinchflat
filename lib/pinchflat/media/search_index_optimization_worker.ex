defmodule Pinchflat.Media.SearchIndexOptimizationWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: :incomplete],
    tags: ["local_data"]

  require Logger

  alias Pinchflat.Media.MediaItemsSearchIndex

  @doc """
  Merges FTS5 index segments of the media_items search index.

  Delete/update churn from retention and indexing accumulates FTS5
  segments and tombstones, which slows down MATCH queries over time.
  This worker is scheduled to run weekly via the Oban Cron plugin,
  after the daily retention worker has had its turn.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Optimizing media search index")
    MediaItemsSearchIndex.optimize()
    :ok
  end
end
