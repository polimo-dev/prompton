defmodule PromptOn.Accounts.Membership.Validations.WithinPlanLimit do
  @moduledoc """
  Refuses `Membership.:add` when the organization already holds
  `Entitlements.limit(plan, :members_per_organization)` members (ADR 0010 §6.4).

  ## Why counting existing rows does not break sign-up

  The check is `count >= limit`, and the **first** owner membership of a fresh organization sees
  `count == 0` while even `:free` allows `1` — so both creation paths (`create_personal` at
  sign-up, `AddCreatorAsOwner` for a team organization) pass unchanged. The second membership of a
  free organization sees `count == 1` and is refused.

  ## Why the system actor is *not* skipped here

  Unlike the other three plan gates, `:add` is a system-only action today (the policy forbids every
  other actor), so skipping the system actor would mean the limit never applies at all. The future
  `:invite` inherits this validation by living on the same resource.

  Personal organizations are skipped entirely: they are single-member by definition and their owner
  row must always be creatable.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Accounts.Membership
  alias PromptOn.Accounts.Organization
  alias PromptOn.Entitlements

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :organization_id) do
      nil -> :ok
      organization_id -> check(organization_id)
    end
  end

  defp check(organization_id) do
    case organization(organization_id) do
      %Organization{personal?: true} ->
        :ok

      %Organization{} = organization ->
        Entitlements.check(
          Entitlements.plan(organization),
          :members_per_organization,
          count(organization_id),
          :plan
        )

      nil ->
        :ok
    end
  end

  defp organization(organization_id) do
    case Ash.get(Organization, organization_id, actor: PromptOn.SystemActor.new()) do
      {:ok, organization} -> organization
      _other -> nil
    end
  end

  defp count(organization_id) do
    Membership
    |> Ash.Query.filter(organization_id == ^organization_id)
    |> Ash.count!(actor: PromptOn.SystemActor.new())
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "the plan limit counts existing rows in Elixir, not SQL"}
  end
end
