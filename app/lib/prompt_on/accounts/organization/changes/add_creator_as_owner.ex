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

  ## The creator's plan comes with them

  `Validations.TeamOrganizationsAllowed` decides whether this organization may exist at all by
  reading the **creator's personal organization's** plan (the interim rule, ADR 0010 §6.3), while
  `Membership.Validations.WithinPlanLimit` counts members against the **new** organization's plan.
  If the new row stayed on `:free`, a paying Team customer would create the organization their plan
  entitles them to and then be unable to add anyone to it, with no self-serve fix (`:set_plan` is
  system-only). So the creator's plan is copied here, before the owner membership is added.
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts

  @impl true
  def change(changeset, _opts, context) do
    case context.actor do
      %PromptOn.Accounts.User{id: user_id} ->
        Ash.Changeset.after_action(changeset, fn _changeset, organization ->
          with {:ok, organization} <- copy_creator_plan(organization, user_id) do
            add_owner(organization, user_id)
          end
        end)

      _other ->
        changeset
    end
  end

  defp copy_creator_plan(organization, user_id) do
    case creator_plan(user_id) do
      :free ->
        {:ok, organization}

      plan ->
        Accounts.set_organization_plan(organization, %{plan: plan},
          actor: PromptOn.SystemActor.new()
        )
    end
  end

  defp creator_plan(user_id) do
    case Accounts.personal_organization_for(user_id, actor: PromptOn.SystemActor.new()) do
      {:ok, %PromptOn.Accounts.Organization{plan: plan}} when not is_nil(plan) -> plan
      _other -> :free
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
