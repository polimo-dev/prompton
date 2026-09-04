defmodule PromptOn.Evals.EvaluationResult.Changes.TallyRun do
  @moduledoc """
  After a result reaches a terminal state, re-tally its run (ADR 0010 §2.6).

  It runs in `after_action` as the system actor. A failure here is swallowed: the `:tally` is
  idempotent and the ten-minute stall sweeper re-runs it, so a lost tally delays a run's completion
  but never loses it. Refusing to write the result because its run could not be tallied would be
  the worse trade.

  At `evals: 4` this is at most four writers on one run row. If that queue concurrency is ever
  raised, throttle the tally (every Nth result plus the last) before raising it.

  An action carrying a `tally?` argument can turn this off (`:mark_failed` does, for the stall
  sweeper's bulk update). An action without the argument always tallies.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_argument(changeset, :tally?) == false do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn _changeset, result -> tally(result) end)
    end
  end

  defp tally(result) do
    PromptOn.Evals.tally_evaluation(result.evaluation_run_id,
      tenant: result.project_id,
      actor: PromptOn.SystemActor.new()
    )

    {:ok, result}
  rescue
    error ->
      Logger.warning(
        "evals: tally of run #{result.evaluation_run_id} failed " <>
          "(the sweeper will retry): #{Exception.message(error)}"
      )

      {:ok, result}
  end
end
