defmodule PromptOn.Evals.EvaluationResult.Changes.RunJudge do
  @moduledoc """
  `EvaluationResult.:score` — the body of one Oban job (ADR 0010 §2.6, §3.1).

  In `before_action` it loads the run and its rubric, reads the log's payload through the existing
  decrypting path, flattens it with `PromptOn.Evals.PayloadText`, asks
  `PromptOn.Evals.Judge.score_sample/5` and force-writes the outcome.

  Three outcomes are **terminal and are not changeset errors**, because there is nothing to retry:

  - the payload is gone (the retention purge got there first) → `:failed`,
    `"payload no longer stored"`;
  - the judge did not answer with JSON → `:unparsable`, excluded from the average and counted
    separately;
  - `{:error, :no_provider_key}` → `:failed`, `"no provider key"` (the key was revoked mid-run).

  Anything else (transport, HTTP) **is** added as a changeset error, so AshOban retries with
  exponential backoff and `on_error :mark_failed` records the failure after the last attempt.

  Nothing here logs payload text, the rendered prompt or the rationale (ADR 0010 §4).
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Evals.{EvaluationRun, Judge, PayloadText}

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &judge(&1, context))
  end

  defp judge(changeset, context) do
    result = changeset.data
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    with {:ok, run} <- load_run(result.evaluation_run_id, opts),
         {:ok, use_case} <- load_use_case(run, opts),
         {:ok, input, output} <- payload(result.generation_id, opts) do
      score(changeset, context, run, use_case, input, output, opts)
    else
      {:terminal, message} -> terminal(changeset, :failed, message, nil)
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp score(changeset, context, run, use_case, input, output, opts) do
    judge_opts = [organization_id: organization_id(opts), model: run.judge_model]

    case Judge.score_sample(use_case, run.rubric, input, output, judge_opts) do
      {:ok, outcome} ->
        write(changeset, context, :scored, run.judge_model, outcome)

      {:error, {:unparsable, _raw}} ->
        terminal(changeset, :unparsable, "the judge did not answer with JSON", run.judge_model)

      {:error, :no_provider_key} ->
        terminal(changeset, :failed, "no provider key", run.judge_model)

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :status,
            message: "judge call failed: #{describe(reason)}"
          )
        )
    end
  end

  defp write(changeset, context, status, judge_model, outcome) do
    changeset
    |> Ash.Changeset.force_change_attributes(%{
      status: status,
      score: outcome.score,
      judge_model: outcome.usage[:model_used] || judge_model,
      latency_ms: outcome.usage[:latency_ms],
      input_tokens: outcome.usage[:input_tokens],
      output_tokens: outcome.usage[:output_tokens],
      cost_usd: outcome.usage[:cost_usd],
      error_message: nil,
      scored_at: DateTime.utc_now()
    })
    |> AshCloak.encrypt_and_set(:rationale, outcome.rationale, context)
  end

  defp terminal(changeset, status, message, judge_model) do
    Ash.Changeset.force_change_attributes(changeset, %{
      status: status,
      judge_model: judge_model || Ash.Changeset.get_attribute(changeset, :judge_model),
      error_message: String.slice(message, 0, 500),
      scored_at: DateTime.utc_now()
    })
  end

  defp load_run(run_id, opts) do
    EvaluationRun
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.Query.load([:rubric])
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} -> {:terminal, "the evaluation run is gone"}
      {:ok, run} -> {:ok, run}
      {:error, error} -> {:error, error}
    end
  end

  defp load_use_case(run, opts) do
    case PromptOn.Prompts.get_use_case(run.use_case_id, opts) do
      {:ok, nil} -> {:terminal, "the use case is gone"}
      {:ok, use_case} -> {:ok, use_case}
      {:error, error} -> {:error, error}
    end
  end

  defp payload(generation_id, opts) do
    case PromptOn.Observability.get_payload(
           generation_id,
           Keyword.put(opts, :load, [:input, :output])
         ) do
      {:ok, nil} ->
        {:terminal, "payload no longer stored"}

      {:ok, payload} ->
        {input, output, _truncated?} = PayloadText.extract(payload)
        {:ok, input, output}

      {:error, _error} ->
        {:terminal, "payload no longer stored"}
    end
  end

  defp organization_id(opts) do
    case PromptOn.Projects.get_project(opts[:tenant], actor: opts[:actor]) do
      {:ok, %{organization_id: organization_id}} -> organization_id
      _other -> nil
    end
  end

  # Only the shape of the failure, never a body: a provider error body can quote the request.
  defp describe(:timeout), do: "timeout"
  defp describe({:request_failed, _reason}), do: "request failed"
  defp describe({:http_error, status, _body}), do: "HTTP #{status}"
  defp describe({:http_error, status, _body, _headers}), do: "HTTP #{status}"
  defp describe({:invalid_response, _body}), do: "invalid provider response"
  defp describe(reason) when is_atom(reason), do: to_string(reason)
  defp describe(_reason), do: "unknown error"
end
