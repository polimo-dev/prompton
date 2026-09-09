defmodule PromptOn.Accounts.Organization.Changes.TransferOwnership do
  @moduledoc """
  Atomically transfers the single organization owner to another existing member.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias PromptOn.Repo

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      organization = changeset.data
      target_user_id = Ash.Changeset.get_argument(changeset, :user_id)

      with :ok <- ensure_team_organization(organization),
           :ok <- transfer(organization.id, actor_id(context.actor), target_user_id) do
        changeset
      else
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp ensure_team_organization(%{personal?: true}) do
    {:error, invalid(:base, "personal organizations cannot transfer ownership")}
  end

  defp ensure_team_organization(_organization), do: :ok

  defp actor_id(%PromptOn.Accounts.User{id: user_id}), do: user_id
  defp actor_id(_actor), do: nil

  defp transfer(organization_id, actor_id, target_user_id)
       when is_binary(organization_id) and is_binary(actor_id) and is_binary(target_user_id) do
    Repo.transaction(fn ->
      lock_organization(organization_id)
      lock_memberships(organization_id)

      with :ok <- require_actor_owner(organization_id, actor_id),
           :ok <- require_target_member(organization_id, target_user_id) do
        demote_current_owners(organization_id)
        promote_target_owner(organization_id, target_user_id)
        :ok
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp transfer(_organization_id, _actor_id, _target_user_id),
    do: {:error, invalid(:user_id, "must be an organization member")}

  defp lock_organization(organization_id) do
    Repo.query!(
      "SELECT id FROM organizations WHERE id = $1 FOR UPDATE",
      [Ecto.UUID.dump!(organization_id)]
    )
  end

  defp lock_memberships(organization_id) do
    Repo.query!(
      "SELECT id FROM memberships WHERE organization_id = $1 FOR UPDATE",
      [Ecto.UUID.dump!(organization_id)]
    )
  end

  defp require_actor_owner(organization_id, actor_id) do
    case role(organization_id, actor_id) do
      :owner -> :ok
      _other -> {:error, invalid(:base, "only the owner can transfer ownership")}
    end
  end

  defp require_target_member(organization_id, user_id) do
    case role(organization_id, user_id) do
      nil -> {:error, invalid(:user_id, "must be an organization member")}
      _role -> :ok
    end
  end

  defp role(organization_id, user_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT role FROM memberships WHERE organization_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(organization_id), Ecto.UUID.dump!(user_id)]
      )

    case rows do
      [[role]] -> String.to_existing_atom(role)
      _other -> nil
    end
  end

  defp demote_current_owners(organization_id) do
    Repo.query!(
      "UPDATE memberships SET role = 'admin', updated_at = now() WHERE organization_id = $1 AND role = 'owner'",
      [Ecto.UUID.dump!(organization_id)]
    )
  end

  defp promote_target_owner(organization_id, user_id) do
    Repo.query!(
      "UPDATE memberships SET role = 'owner', updated_at = now() WHERE organization_id = $1 AND user_id = $2",
      [Ecto.UUID.dump!(organization_id), Ecto.UUID.dump!(user_id)]
    )
  end

  defp invalid(field, message),
    do: InvalidAttribute.exception(field: field, message: message)
end
