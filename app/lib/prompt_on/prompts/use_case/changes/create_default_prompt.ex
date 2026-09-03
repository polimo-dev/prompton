defmodule PromptOn.Prompts.UseCase.Changes.CreateDefaultPrompt do
  @moduledoc """
  Right after `:define`, creates `Prompt(name: "default")` for `:chat`/`:text` use cases in the
  same transaction (plan.md §5.5). `:embedding` has no prompt, so nothing is created.
  """

  use Ash.Resource.Change

  alias PromptOn.Prompts

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, use_case ->
      if use_case.kind in [:chat, :text], do: open_default(use_case), else: {:ok, use_case}
    end)
  end

  defp open_default(use_case) do
    case Prompts.open_prompt(
           %{use_case_id: use_case.id, name: "default"},
           tenant: use_case.project_id,
           actor: PromptOn.SystemActor.new()
         ) do
      {:ok, _prompt} -> {:ok, use_case}
      {:error, error} -> {:error, error}
    end
  end
end
