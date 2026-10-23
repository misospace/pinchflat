defmodule Pinchflat.Media.MediaItemsSearchIndex do
  @moduledoc """
  The MediaItem fts5 search index. Not made to be directly interacted with,
  but I figured it'd be better to have it in-app so it's not a mystery.
  """

  use Ecto.Schema

  alias Pinchflat.Repo

  @primary_key {:id, :id, autogenerate: true, source: :rowid}
  schema "media_items_search_index" do
    field :title, :string
    field :description, :string

    field :rank, :float, virtual: true
  end

  @doc """
  Runs the FTS5 `optimize` command against the search index table.

  FTS5 does not merge or reclaim index segments on its own, so deletes
  and updates (retention culling, metadata refreshes) leave tombstones
  and append segments until this is run. See
  https://sqlite.org/fts5.html#the_optimize_command
  """
  def optimize do
    query = "INSERT INTO media_items_search_index(media_items_search_index) VALUES('optimize')"
    Ecto.Adapters.SQL.query!(Repo, query, [])
    :ok
  end
end
