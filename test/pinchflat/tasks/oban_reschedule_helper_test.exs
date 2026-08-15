defmodule Pinchflat.Tasks.ObanRescheduleHelperTest do
  use ExUnit.Case, async: true

  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures
  alias Pinchflat.Tasks.ObanRescheduleHelper
  alias Pinchflat.FastIndexing.FastIndexingWorker

  setup do
    {:ok, source: source_fixture()}
  end

  test "reschedule inserts a new job and returns {:ok, task}", %{source: source} do
    Oban.drain()

    assert {:ok, %Oban.Job{state: "scheduled", worker: "Elixir." <> _} = task} =
             ObanRescheduleHelper.reschedule(FastIndexingWorker, source, 60)
  end

  test "reschedule normalises :duplicate_job to {:ok, :job_exists}", %{source: source} do
    assert {:ok, _task} = ObanRescheduleHelper.reschedule(FastIndexingWorker, source, 60)

    assert {:ok, :job_exists} = ObanRescheduleHelper.reschedule(FastIndexingWorker, source, 60)
  end

  test "reschedule uses the pending-only states so an :executing sibling does not
        block the reschedule",
       %{source: source} do
    {:ok, existing} =
      Oban.insert(FastIndexingWorker.new(%{id: source.id}, schedule_in: 60),
        state: :executing
      )

    assert {:ok, _task} = ObanRescheduleHelper.reschedule(FastIndexingWorker, source, 60)

    Oban.cancel(existing)
  end

  test "reschedule forwards `next_run_in` seconds as Oban's schedule_in", %{source: source} do
    Oban.drain()

    {:ok, %Oban.Job{scheduled_at: scheduled_at}} =
      ObanRescheduleHelper.reschedule(FastIndexingWorker, source, 90)

    diff = DateTime.diff(scheduled_at, DateTime.utc_now(), :second)

    assert diff > 60 and diff <= 90
  end
end
