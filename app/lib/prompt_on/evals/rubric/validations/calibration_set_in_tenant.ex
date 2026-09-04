defmodule PromptOn.Evals.Rubric.Validations.CalibrationSetInTenant do
  @moduledoc """
  `Rubric.:draft` and `Rubric.:write`: the `calibration_set_id` must name a calibration set of
  **this project** and of **this use case**.

  `use_case_id` is already protected — `Changes.AssignNumber` reads the use case in-tenant, and
  `Changes.CopyFromSource` reads the source rubric in-tenant — but the calibration set was not.
  Attribute multitenancy does not make a foreign key composite, so the database happily accepts a
  set of another project. Nothing leaks (every downstream read is tenant-filtered), but the row is
  a dangling cross-tenant reference and the user gets a nonsense error later
  (`Calibration.revise/2` returning `:no_scored_samples`) instead of a sentence about the set.

  Mirrors `EvaluationRun.Validations.TargetInTenant`.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Evals.CalibrationSet

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :calibration_set_id) do
      nil -> :ok
      id -> check(changeset, id)
    end
  end

  defp check(changeset, id) do
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    CalibrationSet
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} ->
        invalid("calibration set not found in this project")

      {:ok, %CalibrationSet{use_case_id: set_use_case_id}} ->
        matches(changeset, set_use_case_id)

      {:error, error} ->
        {:error, error}
    end
  end

  defp matches(changeset, set_use_case_id) do
    case Ash.Changeset.get_attribute(changeset, :use_case_id) do
      nil -> :ok
      ^set_use_case_id -> :ok
      _other -> invalid("calibration set belongs to another use case")
    end
  end

  defp invalid(message) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(field: :calibration_set_id, message: message)}
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "the calibration set is read in Elixir, not SQL"}
  end
end
