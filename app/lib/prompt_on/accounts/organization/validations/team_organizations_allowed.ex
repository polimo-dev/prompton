defmodule PromptOn.Accounts.Organization.Validations.TeamOrganizationsAllowed do
  @moduledoc """
  Refuses `Organization.:create` (a **team** organization) when the creator's plan does not include
  `:team_organizations` (ADR 0010 §6.3).

  ## Which plan is "the creator's plan"

  There is no billing yet, so "this person's plan" has to mean something concrete. It means the
  plan of **the creator's personal organization** — that is the row the admin app flips for a
  paying person. `Changes.AddCreatorAsOwner` then **copies that plan onto the new organization** in
  the same transaction, because `Membership.Validations.WithinPlanLimit` reads the new row: a team
  organization born on `:free` would accept no second member, which is the opposite of what the
  plan that allowed it to exist entitles the creator to.

  This interim rule lives here in prose because it is not derivable from the code, and it
  disappears the day billing exists.

  The system actor is skipped: seeds, the HeyDiary import and fixtures create team organizations
  on behalf of the product.
  """

  use Ash.Resource.Validation

  alias PromptOn.Accounts
  alias PromptOn.Entitlements

  @impl true
  def validate(_changeset, _opts, context) do
    case context.actor do
      %PromptOn.SystemActor{} -> :ok
      %PromptOn.Accounts.User{id: user_id} -> check(user_id)
      _other -> :ok
    end
  end

  defp check(user_id) do
    plan = creator_plan(user_id)

    if Entitlements.allows?(plan, :team_organizations) do
      :ok
    else
      {:error, Entitlements.error(plan, :team_organizations, :plan)}
    end
  end

  # No personal organization (an account made before the sign-up flow created one) → `:free`,
  # the safe direction for a limit.
  defp creator_plan(user_id) do
    case Accounts.personal_organization_for(user_id, actor: PromptOn.SystemActor.new()) do
      {:ok, %PromptOn.Accounts.Organization{} = organization} -> Entitlements.plan(organization)
      _other -> Entitlements.plan(:free)
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "the creator's plan is loaded in Elixir, not SQL"}
  end
end
