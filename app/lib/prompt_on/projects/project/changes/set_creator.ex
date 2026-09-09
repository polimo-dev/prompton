defmodule PromptOn.Projects.Project.Changes.SetCreator do
  @moduledoc "Sets `creator_id` from the actor during project creation."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %PromptOn.Accounts.User{id: user_id}}) do
    Ash.Changeset.force_change_attribute(changeset, :creator_id, user_id)
  end

  def change(changeset, _opts, _context), do: changeset
end
