defmodule PromptOn.Evals.Calibration do
  @moduledoc """
  The calibration half of the eval loop, as three service functions the Evals tab calls from
  `start_async` (ADR 0010 §1, §5.3).

  - `draft/2` — the AI writes rubric #1 from the human's scores, then scores the same samples with
    it, so the agreement table is there the moment the rubric appears.
  - `revise/2` — a new rubric version from an existing one plus an optional note, scored the same
    way.
  - `score_set/2` — re-score the calibration samples with an existing rubric (the upsert makes this
    idempotent).

  Judge calls run through `PromptOn.Evals.Judge` on the organization's own provider key. Rubric
  rows are written **as the caller** (a project member); calibration scores are written as the
  system actor, because `CalibrationScore.:record` is internal.

  Nothing here logs payload text, prompt text or a rationale (ADR 0010 §4).
  """

  require Ash.Query
  require Logger

  alias PromptOn.Evals
  alias PromptOn.Evals.{CalibrationSample, CalibrationSet, Judge, Rubric}

  @concurrency 4
  @task_timeout 90_000

  @doc """
  Drafts rubric #1 for a calibration set and scores the set with it.

  Options: `:tenant` (required), `:actor` (required — the member on whose behalf the rubric is
  written; the rubric's `authored_by` is derived from that actor).
  """
  @spec draft(CalibrationSet.t(), keyword()) :: {:ok, Rubric.t()} | {:error, term()}
  def draft(%CalibrationSet{} = set, opts) do
    with {:ok, context} <- context(set.use_case_id, set.project_id),
         {:ok, samples} <- scored_samples(set.id, opts),
         judge_opts = judge_opts(nil, context, opts),
         {:ok, criteria, _usage} <- Judge.draft_rubric(context.use_case, samples, judge_opts),
         {:ok, rubric} <- create_draft(set, criteria, opts) do
      score_and_return(rubric, context, samples, opts)
    end
  end

  @doc """
  Revises a rubric into a new version and scores the calibration set with it.

  Options: `:tenant`, `:actor`, `:note` (the expert's revision note). `authored_by` is derived
  from the actor.
  """
  @spec revise(Rubric.t(), keyword()) :: {:ok, Rubric.t()} | {:error, term()}
  def revise(%Rubric{} = rubric, opts) do
    with {:ok, set_id} <- calibration_set_id(rubric),
         {:ok, context} <- context(rubric.use_case_id, rubric.project_id),
         {:ok, samples} <- scored_samples(set_id, opts),
         judge_opts = judge_opts(rubric, context, opts),
         note = Keyword.get(opts, :note),
         {:ok, criteria, _usage} <-
           Judge.revise_rubric(context.use_case, rubric, samples, note, judge_opts),
         {:ok, revised} <- create_revision(rubric, criteria, note, opts) do
      score_and_return(revised, context, samples, opts)
    end
  end

  @doc """
  Scores every scored sample of the rubric's calibration set with that rubric. Returns
  `%{scored: n, unparsable: n, failed: n}`. Re-running upserts, so it never duplicates rows.
  """
  @spec score_set(Rubric.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def score_set(%Rubric{} = rubric, opts) do
    with {:ok, set_id} <- calibration_set_id(rubric),
         {:ok, context} <- context(rubric.use_case_id, rubric.project_id),
         {:ok, samples} <- scored_samples(set_id, opts) do
      {:ok, score_samples(rubric, context, samples, opts)}
    end
  end

  # ---------------------------------------------------------------------------

  defp score_and_return(rubric, context, samples, opts) do
    _tally = score_samples(rubric, context, samples, opts)
    {:ok, rubric}
  end

  defp score_samples(rubric, context, samples, opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    model = Judge.model(rubric, context.organization_id)
    judge_opts = [organization_id: context.organization_id, model: model]

    samples
    |> Task.async_stream(
      fn sample -> {sample, judge(rubric, context.use_case, sample, judge_opts)} end,
      max_concurrency: @concurrency,
      timeout: @task_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{scored: 0, unparsable: 0, failed: 0}, fn
      {:ok, {sample, outcome}}, acc ->
        record(rubric, sample, outcome, model, tenant)
        Map.update!(acc, bucket(outcome), &(&1 + 1))

      {:exit, _reason}, acc ->
        Map.update!(acc, :failed, &(&1 + 1))
    end)
  end

  defp judge(rubric, use_case, sample, judge_opts) do
    Judge.score_sample(
      use_case,
      rubric,
      sample.input_text || "",
      sample.output_text || "",
      judge_opts
    )
  end

  defp bucket({:ok, _result}), do: :scored
  defp bucket({:error, {:unparsable, _raw}}), do: :unparsable
  defp bucket({:error, _reason}), do: :failed

  defp record(rubric, sample, {:ok, result}, model, tenant) do
    write_score(tenant, %{
      rubric_id: rubric.id,
      calibration_sample_id: sample.id,
      status: :ok,
      score: result.score,
      rationale: result.rationale,
      judge_model: result.usage[:model_used] || model,
      latency_ms: result.usage[:latency_ms],
      input_tokens: result.usage[:input_tokens],
      output_tokens: result.usage[:output_tokens],
      cost_usd: result.usage[:cost_usd]
    })
  end

  defp record(rubric, sample, {:error, reason}, model, tenant) do
    {status, message} = failure(reason)

    write_score(tenant, %{
      rubric_id: rubric.id,
      calibration_sample_id: sample.id,
      status: status,
      judge_model: model,
      error_message: message
    })
  end

  # `CalibrationScore.error_message` is **not** encrypted, so only the *shape* of a failure may be
  # written here — the same reducer `EvaluationResult.Changes.RunJudge.describe/1` uses on the batch
  # path. A provider error body can quote the request, and a judge that ignored "JSON only" is
  # exactly the one that echoes the payload back, so neither the body nor the raw answer is stored.
  defp failure({:unparsable, _raw}), do: {:unparsable, "the judge did not answer with JSON"}
  defp failure(:no_provider_key), do: {:failed, "no provider key"}
  defp failure(:timeout), do: {:failed, "timeout"}
  defp failure({:request_failed, _reason}), do: {:failed, "request failed"}
  defp failure({:http_error, status, _body}), do: {:failed, "HTTP #{status}"}
  defp failure({:http_error, status, _body, _headers}), do: {:failed, "HTTP #{status}"}
  defp failure({:invalid_response, _body}), do: {:failed, "invalid provider response"}
  defp failure(reason) when is_atom(reason), do: {:failed, to_string(reason)}
  defp failure(_reason), do: {:failed, "unknown error"}

  defp write_score(tenant, attrs) do
    case Evals.record_calibration_score(attrs, tenant: tenant, actor: PromptOn.SystemActor.new()) do
      {:ok, score} ->
        {:ok, score}

      {:error, error} ->
        # Deliberately id-only: an Ash error carries the changeset attributes, and one of them is
        # the judge rationale (ADR 0010 §4).
        Logger.warning(
          "evals: calibration score not recorded for sample #{attrs.calibration_sample_id}"
        )

        {:error, error}
    end
  end

  # ---------------------------------------------------------------------------

  defp create_draft(set, criteria, opts) do
    Evals.draft_rubric(
      %{
        use_case_id: set.use_case_id,
        calibration_set_id: set.id,
        criteria: criteria
      },
      call_opts(opts)
    )
  end

  defp create_revision(rubric, criteria, note, opts) do
    Evals.revise_rubric(
      rubric.id,
      %{criteria: criteria, note: note},
      call_opts(opts)
    )
  end

  defp call_opts(opts), do: Keyword.take(opts, [:tenant, :actor])

  defp calibration_set_id(%Rubric{calibration_set_id: nil}),
    do: {:error, :no_calibration_set}

  defp calibration_set_id(%Rubric{calibration_set_id: id}), do: {:ok, id}

  # The samples a rubric is written from and measured against: the ones the human actually scored,
  # with their frozen text decrypted for this call only.
  defp scored_samples(set_id, opts) do
    CalibrationSample
    |> Ash.Query.filter(calibration_set_id == ^set_id and not is_nil(user_score))
    |> Ash.Query.sort(position: :asc)
    |> Ash.Query.load([:input_text, :output_text])
    |> Ash.read(tenant: Keyword.fetch!(opts, :tenant), actor: PromptOn.SystemActor.new())
    |> case do
      {:ok, []} -> {:error, :no_scored_samples}
      {:ok, samples} -> {:ok, samples}
      {:error, error} -> {:error, error}
    end
  end

  defp context(use_case_id, project_id) do
    system = PromptOn.SystemActor.new()

    with {:ok, %{} = use_case} <-
           PromptOn.Prompts.get_use_case(use_case_id, tenant: project_id, actor: system),
         {:ok, %{} = project} <- PromptOn.Projects.get_project(project_id, actor: system) do
      {:ok, %{use_case: use_case, organization_id: project.organization_id}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp judge_opts(rubric, context, opts) do
    [
      organization_id: context.organization_id,
      model: Judge.model(rubric, context.organization_id),
      receive_timeout: Keyword.get(opts, :receive_timeout, 60_000)
    ]
  end
end
