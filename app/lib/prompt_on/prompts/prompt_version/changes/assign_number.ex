defmodule PromptOn.Prompts.PromptVersion.Changes.AssignNumber do
  @moduledoc """
  Assigns the monotonically increasing `number` within a Prompt (plan.md §5.5). Inside the
  transaction (before_action) it locks the Prompt row `FOR UPDATE` and then computes
  `max(number)+1`, so two concurrent drafts never receive the same number. The identity
  `:unique_number_per_prompt` is the last line of defense.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Prompts.{Prompt, PromptVersion}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &assign/1)
  end

  defp assign(changeset) do
    prompt_id = Ash.Changeset.get_attribute(changeset, :prompt_id)
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    with {:ok, %Prompt{}} <- lock_prompt(prompt_id, opts),
         {:ok, max} <- max_number(prompt_id, opts) do
      Ash.Changeset.force_change_attribute(changeset, :number, (max || 0) + 1)
    else
      {:ok, nil} ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :prompt_id,
            message: "prompt not found in this project"
          )
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp lock_prompt(prompt_id, opts) do
    Prompt
    |> Ash.Query.filter(id == ^prompt_id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(opts)
  end

  defp max_number(prompt_id, opts) do
    PromptVersion
    |> Ash.Query.filter(prompt_id == ^prompt_id)
    |> Ash.max(:number, opts)
  end
end
