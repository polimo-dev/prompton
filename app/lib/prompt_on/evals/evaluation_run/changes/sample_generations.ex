defmodule PromptOn.Evals.EvaluationRun.Changes.SampleGenerations do
  @moduledoc """
  `EvaluationRun.:start`: picks the logs of this deployment revision x environment that can be
  scored, and writes one pending `EvaluationResult` per log (ADR 0010 §2.6).

  The sampling runs in `before_action` and the result rows are written in `after_action`, where the
  run's id exists — so **the whole thing is one transaction**: either the run and all its results
  exist, or neither does. A run with no eligible logs is refused rather than created empty.

  `sample_limit` is **clamped, not refused** (ADR 0010 §6.5): the user asked for "up to 1,000", and
  silently giving them the maximum their plan allows is friendlier than an error about a number
  they never typed.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Evals.{EvaluationResult, Sampler}

  @default_sample_limit 1_000

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &sample/1)
  end

  defp sample(changeset) do
    tenant = changeset.to_tenant || changeset.tenant
    opts = [tenant: tenant, actor: PromptOn.SystemActor.new()]
    use_case_id = Ash.Changeset.get_attribute(changeset, :use_case_id)
    limit = clamp(Ash.Changeset.get_attribute(changeset, :sample_limit), tenant)

    candidates =
      Sampler.eligible(
        %{id: use_case_id},
        [
          limit: limit,
          deployment_id: Ash.Changeset.get_attribute(changeset, :deployment_id),
          environment_id: Ash.Changeset.get_attribute(changeset, :environment_id)
        ] ++ opts
      )

    case candidates do
      {:ok, []} ->
        Ash.Changeset.add_error(changeset, no_logs_error(changeset, opts))

      {:ok, candidates} ->
        plan(changeset, candidates, limit, opts)

      # Not "there are none": a read failure gets its own sentence, so the user is not told their
      # logs do not exist because the query was refused.
      {:error, _error} ->
        Ash.Changeset.add_error(
          changeset,
          invalid(:deployment_id, "could not read the monitoring logs of this revision")
        )
    end
  end

  defp plan(changeset, candidates, limit, opts) do
    rows =
      candidates
      |> Enum.with_index(1)
      |> Enum.map(fn {generation, position} ->
        %{generation_id: generation.id, position: position}
      end)

    changeset
    |> Ash.Changeset.force_change_attributes(%{
      sample_limit: limit,
      item_count: length(rows),
      window_from: window(candidates, :min),
      window_to: window(candidates, :max)
    })
    |> Ash.Changeset.after_action(fn _changeset, run -> enqueue_results(run, rows, opts) end)
  end

  defp enqueue_results(run, rows, opts) do
    rows = Enum.map(rows, &Map.put(&1, :evaluation_run_id, run.id))

    result =
      Ash.bulk_create(rows, EvaluationResult, :enqueue,
        tenant: opts[:tenant],
        actor: opts[:actor],
        return_errors?: true,
        stop_on_error?: true,
        return_records?: false
      )

    case result do
      %Ash.BulkResult{status: :success} -> {:ok, run}
      %Ash.BulkResult{errors: [error | _rest]} -> {:error, error}
      %Ash.BulkResult{} -> {:error, invalid(:deployment_id, "could not enqueue the evaluation")}
    end
  end

  # The plan's ceiling, not an error (ADR 0010 §6.5). It is 1,000 on every plan today; reading it
  # from `PromptOn.Entitlements` means a future plan difference needs no change here.
  defp clamp(requested, tenant) do
    requested = requested || @default_sample_limit

    tenant
    |> PromptOn.Entitlements.plan_for_project()
    |> PromptOn.Entitlements.limit(:evaluation_sample_limit)
    |> case do
      limit when is_integer(limit) and limit > 0 -> min(requested, limit)
      _other -> requested
    end
  end

  defp no_logs_error(changeset, opts) do
    revision = Ash.Changeset.get_attribute(changeset, :deployment_revision)
    environment = environment_slug(Ash.Changeset.get_attribute(changeset, :environment_id), opts)

    invalid(
      :deployment_id,
      "revision ##{revision} has no monitoring logs with stored log content in #{environment}"
    )
  end

  defp environment_slug(nil, _opts), do: "this environment"

  defp environment_slug(id, opts) do
    PromptOn.Projects.Environment
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %{slug: slug}} -> slug
      _other -> "this environment"
    end
  end

  defp window([], _which), do: nil

  defp window(generations, which) do
    times = generations |> Enum.map(& &1.started_at) |> Enum.reject(&is_nil/1)

    case {times, which} do
      {[], _which} -> nil
      {times, :min} -> Enum.min(times, DateTime)
      {times, :max} -> Enum.max(times, DateTime)
    end
  end

  defp invalid(field, message),
    do: Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)
end
