defmodule PromptOn.Projects.Project.Validations.WithinPlanLimit do
  @moduledoc """
  Refuses `Project.:create` when the owning organization already holds
  `Entitlements.limit(plan, :projects_per_organization)` non-archived projects (ADR 0010 §6.1).

  The count runs as the **system actor**: someone creating their third project must be told the
  limit even if a policy would hide a row from them, and every project in an organization is
  visible to its members anyway. The system actor itself is never blocked — seeds, the HeyDiary
  import and fixtures create projects on behalf of the product, not of a plan.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Entitlements
  alias PromptOn.Projects.Project

  @impl true
  def validate(changeset, _opts, context) do
    organization_id = Ash.Changeset.get_attribute(changeset, :organization_id)

    cond do
      match?(%PromptOn.SystemActor{}, context.actor) -> :ok
      is_nil(organization_id) -> :ok
      true -> check(organization_id)
    end
  end

  defp check(organization_id) do
    plan = Entitlements.plan(organization_id)

    Entitlements.check(plan, :projects_per_organization, count(organization_id), :plan)
  end

  defp count(organization_id) do
    Project
    |> Ash.Query.filter(organization_id == ^organization_id and is_nil(archived_at))
    |> Ash.count!(actor: PromptOn.SystemActor.new())
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "the plan limit counts existing rows in Elixir, not SQL"}
  end
end
