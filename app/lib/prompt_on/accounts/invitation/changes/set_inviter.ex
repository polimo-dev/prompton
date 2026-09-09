defmodule PromptOn.Accounts.Invitation.Changes.SetInviter do
  @moduledoc "Stores the user who created the invitation."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %PromptOn.Accounts.User{id: user_id}}) do
    Ash.Changeset.force_change_attribute(changeset, :inviter_id, user_id)
  end

  def change(changeset, _opts, _context), do: changeset
end
