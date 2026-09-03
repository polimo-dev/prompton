defmodule PromptOn.Prompts.PromptVersion.Changes.SetAuthor do
  @moduledoc """
  Records the actor's id in `author_id` when the actor is a `%PromptOn.Accounts.User{}` (nil for
  ApiKey/System).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %PromptOn.Accounts.User{id: id}}) do
    Ash.Changeset.force_change_attribute(changeset, :author_id, id)
  end

  def change(changeset, _opts, _context), do: changeset
end
