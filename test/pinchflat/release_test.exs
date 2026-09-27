defmodule Pinchflat.ReleaseTest do
  # Not async: these tests drop columns / delete rows on the shared schema. They
  # run inside the sandbox transaction so everything is rolled back on teardown,
  # but they must not run concurrently with other DB tests.
  use Pinchflat.DataCase

  alias Pinchflat.Release

  # Mirrors of the private data in Pinchflat.Release, asserted here so a change to
  # one without the other is caught.
  @fork_columns [
    {"settings", "ignore_unavailable_media"},
    {"media_items", "unavailable_at"},
    {"media_items", "unavailable_reason"},
    {"settings", "yt_dlp_update_policy"},
    {"settings", "yt_dlp_pinned_version"},
    {"settings", "yt_dlp_nightly_baseline"}
  ]

  @fork_versions [20_260_618_215_000, 20_260_625_174_920, 20_260_629_120_000]

  @route_token_migration "priv/repo/migrations/20241230192618_add_route_token_to_settings.exs"

  describe "prep_for_upstream/0" do
    test "drops every fork-only column so the schema matches upstream" do
      for {table, column} <- @fork_columns do
        assert column_exists?(table, column), "expected #{table}.#{column} to exist before prep"
      end

      assert Release.prep_for_upstream() == :ok

      for {table, column} <- @fork_columns do
        refute column_exists?(table, column), "expected #{table}.#{column} to be dropped"
      end
    end

    test "removes the fork migration versions from schema_migrations" do
      for version <- @fork_versions do
        assert migration_recorded?(version), "expected migration #{version} to be recorded before prep"
      end

      Release.prep_for_upstream()

      # With these versions gone from the ledger, a subsequent `migrate` treats
      # them as pending and re-adds the columns (the fork self-heals), while
      # upstream - which has no such migration files - leaves the schema clean.
      for version <- @fork_versions do
        refute migration_recorded?(version), "expected migration #{version} to be removed"
      end
    end

    test "does not touch columns that upstream also has" do
      Release.prep_for_upstream()

      # Sample of pre-existing upstream columns that must survive the revert.
      assert column_exists?("settings", "yt_dlp_version")
      assert column_exists?("media_items", "media_downloaded_at")
      assert column_exists?("sources", "collection_id")
    end

    test "is idempotent - safe to re-run once everything is already reverted" do
      assert Release.prep_for_upstream() == :ok
      assert Release.prep_for_upstream() == :ok

      for {table, column} <- @fork_columns do
        refute column_exists?(table, column)
      end
    end
  end

  describe "route_token migration" do
    # Static check: reads the migration source rather than the live schema, so it
    # holds regardless of when this database was last migrated. The guard against
    # reintroducing the guessable OPML access-key sentinel must not depend on
    # whether the edited migration happens to have run against this DB.
    test "adds route_token with no sentinel default and no NOT NULL" do
      add_line = @route_token_migration |> File.stream!() |> Enum.find(&(&1 =~ ~r/add\s+:route_token\b/))

      assert is_binary(add_line), "expected the migration to add the route_token column"
      refute add_line =~ "default:"
      refute add_line =~ "null: false"
    end

    test "backfills route_token with a UUID, never the sentinel" do
      assert File.read!(@route_token_migration) =~ "gen_random_uuid()"
      assert count_settings_with_route_token("tmp-token") == 0
    end

    test "route_token exists as a column on a migrated database" do
      # `mix test` creates and migrates a fresh database (CI), so this exercises
      # the edited migration end to end rather than whatever a stale dev DB has.
      assert column_exists?("settings", "route_token")
    end
  end

  defp column_exists?(table, column) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(Pinchflat.Repo, "SELECT name FROM pragma_table_info(?)", [table])

    Enum.any?(rows, fn [name] -> name == column end)
  end

  defp migration_recorded?(version) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(Pinchflat.Repo, "SELECT count(*) FROM schema_migrations WHERE version = ?", [version])

    count > 0
  end

  defp count_settings_with_route_token(token) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(Pinchflat.Repo, "SELECT count(*) FROM settings WHERE route_token = ?", [token])

    count
  end
end
