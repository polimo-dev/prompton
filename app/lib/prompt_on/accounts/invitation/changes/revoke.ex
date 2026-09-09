defmodule PromptOn.Accounts.Invitation.Changes.Revoke do
  @moduledoc """
  Locks and revokes a currently pending invitation.

  The LiveView may hold a stale struct, so revocation re-reads the row under `FOR UPDATE` and
  validates the actor's current invite permissions before stamping `revoked_at`.
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts.Invitation
  alias PromptOn.Accounts.Organization

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:revoked_at, DateTime.utc_now())
    |> Ash.Changeset.before_action(fn changeset ->
      case lock_current(changeset.data.id) do
        %Invitation{} = current ->
          validate_current(changeset, current, context.actor)

        nil ->
          add_error(changeset, :id, "is not accessible")
      end
    end)
  end

  defp lock_current(id) do
    Invitation
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(actor: PromptOn.SystemActor.new())
  end

  defp validate_current(changeset, invitation, actor) do
    with :ok <- pending(invitation),
         :ok <- lock_organization(invitation.organization_id),
         :ok <-
           Invitation.Policy.authorize_invite(
             actor,
             invitation.organization_id,
             invitation.role,
             invitation.project_ids
           ) do
      changeset
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp lock_organization(organization_id) do
    Organization
    |> Ash.Query.filter(id == ^organization_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: PromptOn.SystemActor.new())
    |> case do
      {:ok, %Organization{}} -> :ok
      {:ok, nil} -> {:error, invalid(:organization_id, "is not accessible")}
      {:error, error} -> {:error, error}
    end
  end

  defp pending(invitation) do
    if Invitation.pending?(invitation),
      do: :ok,
      else: {:error, invalid(:revoked_at, "invitation is no longer pending")}
  end

  defp add_error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, invalid(field, message))

  defp invalid(field, message),
    do: Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)
end
