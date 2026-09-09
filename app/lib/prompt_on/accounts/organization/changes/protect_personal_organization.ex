defmodule PromptOn.Accounts.Organization.Changes.ProtectPersonalOrganization do
  @moduledoc """
  Blocks destructive organization actions for personal organizations and stale owners.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias PromptOn.Repo

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      with {:ok, organization} <- lock_current_organization(changeset.data.id),
           :ok <- reject_personal(organization),
           :ok <- authorize_current_owner(context.actor, organization.id) do
        changeset
      else
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp lock_current_organization(organization_id) when is_binary(organization_id) do
    %{rows: rows} =
      Repo.query!(
        ~s(SELECT id, "personal?" FROM organizations WHERE id = $1 FOR UPDATE),
        [Ecto.UUID.dump!(organization_id)]
      )

    case rows do
      [[_id, personal?]] -> {:ok, %{id: organization_id, personal?: personal?}}
      _other -> {:error, invalid("organization no longer exists")}
    end
  end

  defp reject_personal(%{personal?: true}),
    do: {:error, invalid("personal organizations cannot be destroyed")}

  defp reject_personal(_organization), do: :ok

  defp authorize_current_owner(%PromptOn.SystemActor{}, _organization_id), do: :ok

  defp authorize_current_owner(%PromptOn.Accounts.User{id: user_id}, organization_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT role
        FROM memberships
        WHERE organization_id = $1
        AND user_id = $2
        """,
        [Ecto.UUID.dump!(organization_id), Ecto.UUID.dump!(user_id)]
      )

    case rows do
      [["owner"]] ->
        :ok

      _other ->
        {:error, invalid("only the current organization owner can destroy the organization")}
    end
  end

  defp authorize_current_owner(_actor, _organization_id),
    do: {:error, invalid("only the current organization owner can destroy the organization")}

  defp invalid(message),
    do: InvalidAttribute.exception(field: :base, message: message)
end
