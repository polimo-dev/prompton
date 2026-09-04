defmodule PromptOn.Evals.Rubric.Changes.CopyFromSource do
  @moduledoc """
  `:revise` and `:write`: copies `use_case_id` and `calibration_set_id` from the source rubric
  (`source_rubric_id`), plus `judge_model` when the caller left it nil, and records the source
  (ADR 0010 §2.4).

  The source is looked up in the same tenant only. `:write` may be called without a source (a
  hand-written first rubric), in which case this change does nothing and `use_case_id` comes from
  the caller. When both a source and a `use_case_id` are given, they must agree — a rubric may not
  be revised onto another use case.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Evals.Rubric

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :source_rubric_id) do
      nil -> changeset
      source_id -> copy(changeset, source_id)
    end
  end

  defp copy(changeset, source_id) do
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    Rubric
    |> Ash.Query.filter(id == ^source_id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %Rubric{} = source} -> apply_source(changeset, source)
      {:ok, nil} -> invalid(changeset, "source rubric not found in this project")
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp apply_source(changeset, source) do
    given_use_case_id = Ash.Changeset.get_attribute(changeset, :use_case_id)

    if is_nil(given_use_case_id) or given_use_case_id == source.use_case_id do
      Ash.Changeset.force_change_attributes(changeset, %{
        use_case_id: source.use_case_id,
        calibration_set_id:
          Ash.Changeset.get_attribute(changeset, :calibration_set_id) || source.calibration_set_id,
        judge_model: Ash.Changeset.get_attribute(changeset, :judge_model) || source.judge_model
      })
    else
      invalid(changeset, "source rubric belongs to another use case")
    end
  end

  defp invalid(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidArgument.exception(field: :source_rubric_id, message: message)
    )
  end
end
