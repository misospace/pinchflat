defmodule Pinchflat.Tasks.ObanRescheduleHelper do
  @moduledoc """
  Shared logic for re-enqueuing an Oban worker from inside the worker itself.

  The default Oban uniqueness check dedupes new jobs against `:incomplete`
  states, which include `:executing`, to prevent concurrent indexing of the
  same record. A reschedule, however, runs from _inside_ the executing job,
  so deduping against `:executing` would treat the still-running job as a
  duplicate of its own successor and silently skip rescheduling. This helper
  reschedules jobs and dedupes against pending states only
  (`:available`, `:scheduled`, `:retryable`) so the next run is always
  enqueued, while still preventing duplicate pending jobs.
  """

  alias Pinchflat.Tasks

  # When rescheduling from inside an executing job we cannot include
  # `:executing` in the dedupe state list, because the current job is itself
  # `:executing` and would shadow the new one. Limiting to pending states lets
  # the reschedule always succeed while still rejecting duplicate pending jobs.
  @reschedule_unique_opts [period: :infinity, states: [:available, :scheduled, :retryable]]

  @doc """
  Re-enqueues `worker_module` for `attached_record` to run `next_run_in`
  seconds from now, deduplicating against pending Oban job states
  (`:available`, `:scheduled`, `:retryable`).

  Returns `{:ok, task}` on insert, or `{:ok, :job_exists}` when a pending job
  was already enqueued for the record. Other return values from
  `Tasks.create_job_with_task/2` are passed through unchanged.
  """
  def reschedule(worker_module, attached_record, next_run_in) do
    job =
      worker_module.new(%{id: attached_record.id},
        schedule_in: next_run_in,
        unique: @reschedule_unique_opts
      )

    case Tasks.create_job_with_task(job, attached_record) do
      {:ok, task} -> {:ok, task}
      {:error, :duplicate_job} -> {:ok, :job_exists}
      other -> other
    end
  end
end
