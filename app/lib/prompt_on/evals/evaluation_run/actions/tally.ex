defmodule PromptOn.Evals.EvaluationRun.Actions.Tally do
  @moduledoc """
  Implements `EvaluationRun.:tally` (ADR 0010 §2.6).

  Loads the `results_*` aggregates and **freezes** them onto the run, then moves the state machine:

  - the first tally of a `:queued` run flips it to `:running`;
  - when nothing is pending any more it `:complete`s — or `:fail`s, when the run enqueued items and
    scored none of them;
  - a losing race on that transition (`AshStateMachine` refuses `:completed -> :completed`) is
    caught and ignored. That is exactly why this resource has a state machine.

  Returns `%{status: atom, pending: integer}`.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PromptOn.Evals.EvaluationRun

  @aggregates [
    :results_total,
    :results_pending,
    :results_scored,
    :results_unparsable,
    :results_failed,
    :results_score_1,
    :results_score_2,
    :results_score_3,
    :results_score_4,
    :results_score_5,
    :results_score_avg,
    :results_cost
  ]

  @impl true
  def run(input, _opts, _context) do
    run_id = Ash.ActionInput.get_argument(input, :evaluation_run_id)
    opts = [tenant: input.tenant, actor: PromptOn.SystemActor.new()]

    case load(run_id, opts) do
      {:ok, nil} -> {:ok, %{status: :missing, pending: 0}}
      {:ok, run} -> {:ok, finalize(run, opts)}
      {:error, error} -> {:error, error}
    end
  end

  defp load(run_id, opts) do
    EvaluationRun
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.Query.load(@aggregates)
    |> Ash.read_one(opts)
  end

  defp finalize(run, opts) do
    freeze(run, opts)
    pending = run.results_pending

    status =
      cond do
        pending > 0 and run.status == :queued ->
          transition(run, :mark_running, %{}, opts)

        pending > 0 ->
          run.status

        run.results_scored == 0 and run.item_count > 0 ->
          transition(run, :fail, failure(run), opts)

        true ->
          transition(run, :complete, %{}, opts)
      end

    %{status: status, pending: pending}
  end

  defp freeze(run, opts) do
    attrs = %{
      scored_count: run.results_scored,
      unparsable_count: run.results_unparsable,
      failed_count: run.results_failed,
      average_score: decimal(run.results_score_avg),
      score_distribution: distribution(run),
      cost_usd: decimal(run.results_cost)
    }

    run
    |> Ash.Changeset.for_update(:record_tally, attrs, opts)
    |> update()
  end

  defp transition(run, action, attrs, opts) do
    run
    |> Ash.Changeset.for_update(action, attrs, opts)
    |> update()
    |> case do
      {:ok, updated} -> updated.status
      {:error, _error} -> run.status
    end
  end

  # `:tally` is called from `EvaluationResult`'s after_action hook, i.e. inside that update's
  # transaction, where Ash cannot deliver notifications and warns about it. No resource in
  # `PromptOn.Evals` declares a notifier — the Evals tab polls the run row (ADR 0010 §5.3, chosen
  # over PubSub on purpose) — so the notifications are asked for and dropped.
  defp update(changeset) do
    case Ash.update(changeset, return_notifications?: true) do
      {:ok, record, _notifications} -> {:ok, record}
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp failure(run) do
    %{
      error_message:
        "every item failed — #{run.results_failed} failed, #{run.results_unparsable} unparsable"
    }
  end

  defp distribution(run) do
    Map.new(1..5, fn n -> {Integer.to_string(n), Map.get(run, :"results_score_#{n}") || 0} end)
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(_value), do: nil
end
