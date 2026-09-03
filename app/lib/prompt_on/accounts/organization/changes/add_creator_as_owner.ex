defmodule PromptOn.Accounts.Organization.Changes.AddCreatorAsOwner do
  @moduledoc """
  Adds the person who created a team organization as its **first owner member**, in the same
  transaction.

  When organization creation was opened up to the UI (2026-09-01) the policy became "any signed-in
  user can create a team organization". But the organization's **read** policy is still the
  member filter (`PromptOn.Checks.OrganizationMember`), so without a membership the creator
  cannot read back the organization they just made; the membership has to be created at the
  moment of creation for the organization to exist at all.

  `Membership :add` is system only, so it is called as `PromptOn.SystemActor` (that resource's
  bypass short-circuits). If the actor is not a user (system seeds etc.) nothing is done; seeds
  create the memberships they want themselves.
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts

  @impl true
  def change(changeset, _opts, context) do
    case context.actor do
      %PromptOn.Accounts.User{id: user_id} ->
        Ash.Changeset.after_action(changeset, fn _changeset, organization ->
          add_owner(organization, user_id)
        end)

      _other ->
        changeset
    end
  end

  defp add_owner(organization, user_id) do
    case Accounts.add_member(
           %{organization_id: organization.id, user_id: user_id, role: :owner},
           actor: PromptOn.SystemActor.new()
         ) do
      {:ok, _membership} -> {:ok, organization}
      {:error, error} -> {:error, error}
    end
  end
end
