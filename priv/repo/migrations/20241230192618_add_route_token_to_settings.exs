defmodule Pinchflat.Repo.Migrations.AddRouteTokenToSettings do
  use Ecto.Migration

  # SQLite cannot add a NOT NULL column without a constant default, and the old
  # "tmp-token" default left a window where a reader could observe the sentinel
  # (route_token is also the OPML access key). The column is therefore added
  # nullable and immediately backfilled with a real per-row UUID. A NULL token is
  # unreachable: the seed migration inserts the only settings row and no code
  # path creates or nulls one afterwards.
  def change do
    alter table(:settings) do
      add :route_token, :string
    end

    execute "UPDATE settings SET route_token = gen_random_uuid() WHERE route_token IS NULL", "SELECT 1;"
  end
end
