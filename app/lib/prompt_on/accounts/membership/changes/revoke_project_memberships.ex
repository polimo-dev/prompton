defmodule PromptOn.Accounts.Membership.Changes.RevokeProjectMemberships do
  @moduledoc "Deletes project-level grants when an organization membership is removed."

  use Ash.Resource.Change

  alias PromptOn.Repo

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      revoke(changeset.data.organization_id, changeset.data.user_id)
      changeset
    end)
  end

  defp revoke(organization_id, user_id) when is_binary(organization_id) and is_binary(user_id) do
    Repo.query!(
      """
      DELETE FROM project_memberships
      WHERE user_id = $1
      AND project_id IN (
        SELECT id FROM projects WHERE organization_id = $2
      )
      """,
      [Ecto.UUID.dump!(user_id), Ecto.UUID.dump!(organization_id)]
    )
  end

  defp revoke(_organization_id, _user_id), do: :ok
end
