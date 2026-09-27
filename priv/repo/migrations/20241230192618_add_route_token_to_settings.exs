defmodule Pinchflat.Repo.Migrations.AddRouteTokenToSettings do
  use Ecto.Migration

  # The route_token column (also the OPML access key) was originally added NOT
  # NULL with a "tmp-token" default and immediately backfilled, because SQLite
  # requires a constant default when adding a NOT NULL column to a populated
  # table. That left a window where a concurrent reader could observe the
  # guessable sentinel, and any copy that skipped the backfill kept it.
  #
  # The column is now added nullable and backfilled with a real per-row UUID, so
  # the sentinel never exists. A NULL token is unreachable in practice: the seed
  # migration inserts the only settings row and no code path creates or nulls one.
  #
  # Existing installs already ran the original migration and, because SQLite
  # cannot drop a column default without a full table rebuild, keep an inert
  # sentinel default in their schema. It is unreachable - no path inserts into
  # settings and every existing row already holds a UUID - so only freshly
  # created databases get the clean DDL.
  def change do
    alter table(:settings) do
      add :route_token, :string
    end

    execute "UPDATE settings SET route_token = gen_random_uuid() WHERE route_token IS NULL;", "SELECT 1;"
  end
end
