defmodule PromptOn.Accounts.Membership.Changes.LockOrganizationAndAuthorize do
  @moduledoc """
  Locks the organization row before membership mutations and revalidates actor permissions.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias PromptOn.Accounts.Permissions
  alias PromptOn.Repo

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      membership = changeset.data
      lock_organization(membership.organization_id)

      if authorized?(context.actor, current_membership(membership)) do
        changeset
      else
        Ash.Changeset.add_error(
          changeset,
          invalid("is not authorized for this membership change")
        )
      end
    end)
  end

  defp authorized?(%PromptOn.Accounts.User{} = actor, %{
         role: role,
         organization_id: organization_id
       }) do
    actor_role = Permissions.role(actor, organization_id)
    target_role = Permissions.normalize_role(role)

    case {actor_role, target_role} do
      {:owner, target} when target in [:admin, :member] -> true
      {role, :member} when role in [:owner, :admin] -> true
      {role, nil} when role in [:owner, :admin] -> true
      _other -> false
    end
  end

  defp authorized?(_actor, _membership), do: false

  defp lock_organization(organization_id) when is_binary(organization_id) do
    Repo.query!(
      "SELECT id FROM organizations WHERE id = $1 FOR UPDATE",
      [Ecto.UUID.dump!(organization_id)]
    )
  end

  defp current_membership(%{id: id} = membership) when is_binary(id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT role FROM memberships WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    case rows do
      [[role]] -> %{membership | role: String.to_existing_atom(role)}
      _other -> nil
    end
  end

  defp current_membership(membership), do: membership

  defp invalid(message),
    do: InvalidAttribute.exception(field: :base, message: message)
end
