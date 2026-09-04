defmodule PromptOn.Evals.CalibrationScore.Changes.ComputeError do
  @moduledoc """
  Denormalizes `absolute_error` and `within_one?` from the sample's human score (ADR 0010 §2.5).

  It runs in `before_action` and reads the sample as the system actor. Both fields are stored so
  the agreement aggregates on `Rubric` (`mean_absolute_error`, `within_one_ratio`, `exact_ratio`)
  are plain SQL over indexed columns instead of a join plus arithmetic per row.

  A score that is not `:ok`, or a sample the human has not scored yet, leaves both fields nil/false
  — the aggregates filter on `status == :ok`, so such a row is simply not counted.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Evals.CalibrationSample

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &compute/1)
  end

  defp compute(changeset) do
    status = Ash.Changeset.get_attribute(changeset, :status)
    score = Ash.Changeset.get_attribute(changeset, :score)
    sample_id = Ash.Changeset.get_attribute(changeset, :calibration_sample_id)

    case {status, score, user_score(sample_id, changeset)} do
      {:ok, score, user_score} when is_integer(score) and is_integer(user_score) ->
        error = abs(score - user_score)

        Ash.Changeset.force_change_attributes(changeset, %{
          absolute_error: error,
          within_one?: error <= 1
        })

      _other ->
        Ash.Changeset.force_change_attributes(changeset, %{
          absolute_error: nil,
          within_one?: false
        })
    end
  end

  defp user_score(nil, _changeset), do: nil

  defp user_score(sample_id, changeset) do
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    CalibrationSample
    |> Ash.Query.filter(id == ^sample_id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %CalibrationSample{user_score: user_score}} -> user_score
      _other -> nil
    end
  end
end
