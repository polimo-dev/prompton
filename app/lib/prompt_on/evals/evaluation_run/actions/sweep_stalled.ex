defmodule PromptOn.Evals.EvaluationRun.Actions.SweepStalled do
  @moduledoc """
  Implements `EvaluationRun.:sweep_stalled` — the ten-minute safety net (ADR 0010 §3.1b).

  For every run that is still `:queued` or `:running`:

  - nothing pending any more → `:tally`, which finalizes a run whose last tally was lost to a
    crash;
  - otherwise, older than `stall_after_seconds` → `:fail` with the partial counts, and the
    still-pending results are bulk-updated to `:failed` so nothing keeps getting rescheduled.

  Returns `%{finalized: n, failed: n}` and emits `[:prompton, :evals, :sweep]`.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PromptOn.Evals.{EvaluationResult, EvaluationRun}

  @impl true
  def run(input, _opts, _context) do
    stall_after = Ash.ActionInput.get_argument(input, :stall_after_seconds) || 7_200
    opts = [tenant: input.tenant, actor: PromptOn.SystemActor.new()]
    started = System.monotonic_time()

    tally =
      Enum.reduce(
        active_runs(opts),
        %{finalized: 0, failed: 0},
        &sweep(&1, &2, stall_after, opts)
      )

    :telemetry.execute(
      [:prompton, :evals, :sweep],
      Map.put(tally, :duration, System.monotonic_time() - started),
      %{tenant: input.tenant}
    )

    {:ok, tally}
  end

  defp active_runs(opts) do
    EvaluationRun
    |> Ash.Query.for_read(:active, %{}, opts)
    |> Ash.Query.load([:results_pending, :results_scored])
    |> Ash.read()
    |> case do
      {:ok, runs} -> runs
      {:error, _error} -> []
    end
  end

  defp sweep(run, tally, stall_after, opts) do
    cond do
      run.results_pending == 0 ->
        _ = PromptOn.Evals.tally_evaluation(run.id, opts)
        Map.update!(tally, :finalized, &(&1 + 1))

      stalled?(run, stall_after) ->
        fail(run, opts)
        Map.update!(tally, :failed, &(&1 + 1))

      true ->
        tally
    end
  end

  defp stalled?(run, stall_after) do
    since = run.started_at || run.inserted_at
    not is_nil(since) and DateTime.diff(DateTime.utc_now(), since, :second) > stall_after
  end

  # The still-pending results are failed with `tally?: false`: `:mark_failed` normally re-tallies
  # its run, and a stalled 1,000-item run would fire a thousand full re-tallies of a run this
  # function has already transitioned to `:failed`. One tally at the end freezes the counters.
  defp fail(run, opts) do
    message =
      "evaluation timed out — #{run.results_scored}/#{run.item_count} scored"

    EvaluationResult
    |> Ash.Query.filter(evaluation_run_id == ^run.id and status == :pending)
    |> Ash.bulk_update(:mark_failed, %{error: :evaluation_timed_out, tally?: false},
      tenant: opts[:tenant],
      actor: opts[:actor],
      strategy: [:stream],
      return_records?: false,
      notify?: false
    )

    run
    |> Ash.Changeset.for_update(:fail, %{error_message: message}, opts)
    |> Ash.update()

    _ = PromptOn.Evals.tally_evaluation(run.id, opts)

    :ok
  end
end
