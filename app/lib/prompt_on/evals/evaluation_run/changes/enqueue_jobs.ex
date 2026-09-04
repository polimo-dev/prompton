defmodule PromptOn.Evals.EvaluationRun.Changes.EnqueueJobs do
  @moduledoc """
  `EvaluationRun.:start`: inserts one `:score` job per result **after the transaction commits**
  (ADR 0010 §3.1).

  The trigger's cron scheduler would find these rows within two minutes on its own; this hook only
  removes that latency. So a failed insert is **logged and swallowed** — the run still finishes,
  just later. That is what makes the enqueue safe rather than load-bearing, and it is why the
  scheduler is kept even though every run enqueues its own jobs.

  Both paths together are safe because AshOban's generated worker is unique on
  `[:primary_key, :action_arguments, :tenant]` while a job is incomplete, so the scheduler's insert
  for a row that already has a job is a no-op.

  ## Why `Oban.insert_all/1` and not `AshOban.run_triggers/3`

  `run_triggers/3` inserts the jobs **one at a time** on the Basic engine, so a 1,000-item run meant
  a thousand round-trips inside the LiveView's `handle_event` before the flash appeared. The jobs
  are built the same way (`AshOban.build_trigger/3`) and inserted in chunks instead.

  `Oban.insert_all/1` does not apply Oban's uniqueness (Oban Pro only), so this insert is not
  deduplicated against the scheduler's. That is safe and deliberate: this hook runs exactly once per
  run, and a duplicate job — the scheduler inserting in the same instant — finds nothing to do,
  because the worker reads through `EvaluationResult.:scorable`, which only returns items that are
  still `:pending` (idempotency layer 2 of ADR 0010 §3.1).
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias PromptOn.Evals.EvaluationResult

  # One round-trip per 500 jobs: a full 1,000-item run is two inserts, not a thousand.
  @chunk_size 500

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &enqueue/2)
  end

  defp enqueue(_changeset, {:ok, run} = result) do
    _ = run_triggers(run)
    result
  end

  defp enqueue(_changeset, result), do: result

  defp run_triggers(run) do
    EvaluationResult
    |> Ash.Query.filter(evaluation_run_id == ^run.id and status == :pending)
    |> Ash.read!(tenant: run.project_id, actor: PromptOn.SystemActor.new())
    |> Enum.map(&AshOban.build_trigger(&1, :score, tenant: run.project_id))
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(&Oban.insert_all/1)
  rescue
    error ->
      Logger.warning(
        "evals: could not enqueue score jobs for run #{run.id} " <>
          "(the scheduler will pick them up): #{Exception.message(error)}"
      )

      :error
  end
end
