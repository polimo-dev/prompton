defmodule PromptOn.Evals.CalibrationSet.Changes.SampleGenerations do
  @moduledoc """
  Implements `CalibrationSet.:sample` (ADR 0010 §2.1).

  In `before_action` (so it is inside the create transaction) it asks
  `PromptOn.Evals.Sampler` for the 200 most recent eligible logs of the use case, picks
  `sample_size` of them evenly spaced, and records `candidate_count` and the sample window. The
  frozen `CalibrationSample` rows are written in `after_action`, where the set's id exists — so
  either the set and all its samples are committed, or neither is.

  Fewer than `@minimum_candidates` eligible logs is refused with the count in the message: a
  half-empty calibration set is worse than none.

  The payload text passes through `PromptOn.Evals.PayloadText` and is never logged.
  """

  use Ash.Resource.Change

  alias PromptOn.Evals.{CalibrationSample, PayloadText, Sampler}

  @candidate_limit 200
  @minimum_candidates 5

  @doc "How many eligible logs the sampler looks at before spacing its picks."
  @spec candidate_limit() :: pos_integer()
  def candidate_limit, do: @candidate_limit

  @doc "Fewer eligible logs than this and `:sample` refuses."
  @spec minimum_candidates() :: pos_integer()
  def minimum_candidates, do: @minimum_candidates

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &sample/1)
  end

  defp sample(changeset) do
    tenant = changeset.to_tenant || changeset.tenant
    opts = [tenant: tenant, actor: PromptOn.SystemActor.new()]
    use_case_id = Ash.Changeset.get_attribute(changeset, :use_case_id)
    size = Ash.Changeset.get_attribute(changeset, :sample_size) || 10

    with {:ok, use_case} <- fetch_use_case(use_case_id, opts),
         {:ok, candidates} <- eligible(use_case, opts),
         :ok <- enough?(candidates) do
      picked = Sampler.pick(candidates, size)
      rows = Enum.map(Enum.with_index(picked, 1), &row(&1, opts))

      changeset
      |> Ash.Changeset.force_change_attributes(%{
        candidate_count: length(candidates),
        window_from: window(picked, :min),
        window_to: window(picked, :max)
      })
      |> Ash.Changeset.after_action(fn _changeset, set -> capture(set, rows, opts) end)
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # A read failure is not "there are none": it gets its own sentence, so nobody is told their logs
  # do not exist because a query was refused.
  defp eligible(use_case, opts) do
    case Sampler.eligible(use_case, [limit: @candidate_limit] ++ opts) do
      {:ok, candidates} -> {:ok, candidates}
      {:error, _error} -> {:error, invalid("could not read the monitoring logs of this use case")}
    end
  end

  defp fetch_use_case(nil, _opts), do: {:error, invalid("use case is required")}

  defp fetch_use_case(id, opts) do
    case PromptOn.Prompts.get_use_case(id, opts) do
      {:ok, nil} -> {:error, invalid("use case not found in this project")}
      {:ok, use_case} -> {:ok, use_case}
      {:error, error} -> {:error, error}
    end
  end

  defp enough?(candidates) when length(candidates) >= @minimum_candidates, do: :ok

  defp enough?(candidates) do
    {:error,
     invalid(
       "needs at least #{@minimum_candidates} monitoring logs with stored log content; " <>
         "this use case has #{length(candidates)}"
     )}
  end

  defp row({generation, position}, opts) do
    {input, output, truncated?} =
      generation.id
      |> read_payload(opts)
      |> PayloadText.extract()

    %{
      generation_id: generation.id,
      position: position,
      input_text: input,
      output_text: output,
      truncated?: truncated?,
      model: generation.model,
      deployment_revision: generation.deployment_revision,
      started_at: generation.started_at
    }
  end

  defp read_payload(generation_id, opts) do
    case PromptOn.Observability.get_payload(
           generation_id,
           Keyword.put(opts, :load, [:input, :output])
         ) do
      {:ok, payload} -> payload
      {:error, _error} -> nil
    end
  end

  defp capture(set, rows, opts) do
    rows = Enum.map(rows, &Map.put(&1, :calibration_set_id, set.id))

    result =
      Ash.bulk_create(rows, CalibrationSample, :capture,
        tenant: opts[:tenant],
        actor: opts[:actor],
        return_errors?: true,
        stop_on_error?: true,
        return_records?: false
      )

    case result do
      %Ash.BulkResult{status: :success} -> {:ok, set}
      %Ash.BulkResult{errors: [error | _rest]} -> {:error, error}
      %Ash.BulkResult{} -> {:error, invalid("could not freeze the sampled logs")}
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

  defp invalid(message),
    do: Ash.Error.Changes.InvalidAttribute.exception(field: :use_case_id, message: message)
end
