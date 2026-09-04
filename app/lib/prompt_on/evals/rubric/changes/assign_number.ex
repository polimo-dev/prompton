defmodule PromptOn.Evals.Rubric.Changes.AssignNumber do
  @moduledoc """
  Assigns the monotonically increasing `number` within a UseCase (ADR 0010 §2.4).

  The same shape as `PromptOn.Prompts.PromptVersion.Changes.AssignNumber`, with `UseCase` as the
  locked parent: inside the transaction (`before_action`) it locks the UseCase row `FOR UPDATE` and
  then computes `max(number) + 1`, so two concurrent drafts never receive the same number. The
  identity `:unique_number_per_use_case` is the last line of defense.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Evals.Rubric
  alias PromptOn.Prompts.UseCase

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &assign/1)
  end

  defp assign(changeset) do
    use_case_id = Ash.Changeset.get_attribute(changeset, :use_case_id)
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    with {:ok, %UseCase{}} <- lock_use_case(use_case_id, opts),
         {:ok, max} <- max_number(use_case_id, opts) do
      Ash.Changeset.force_change_attribute(changeset, :number, (max || 0) + 1)
    else
      {:ok, nil} ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :use_case_id,
            message: "use case not found in this project"
          )
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp lock_use_case(nil, _opts), do: {:ok, nil}

  defp lock_use_case(use_case_id, opts) do
    UseCase
    |> Ash.Query.filter(id == ^use_case_id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(opts)
  end

  defp max_number(use_case_id, opts) do
    Rubric
    |> Ash.Query.filter(use_case_id == ^use_case_id)
    |> Ash.max(:number, opts)
  end
end
