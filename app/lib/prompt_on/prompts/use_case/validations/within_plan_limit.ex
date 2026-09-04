defmodule PromptOn.Prompts.UseCase.Validations.WithinPlanLimit do
  @moduledoc """
  Refuses `UseCase.:define` when the project already holds
  `Entitlements.limit(plan, :use_cases_per_project)` non-archived use cases (ADR 0010 §6.2).

  The plan comes from the tenant (`Entitlements.plan_for_project/1`), and the system actor is
  never blocked (seeds, the HeyDiary import, fixtures).
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Entitlements
  alias PromptOn.Prompts.UseCase

  @impl true
  def validate(changeset, _opts, context) do
    tenant = changeset.tenant

    cond do
      match?(%PromptOn.SystemActor{}, context.actor) -> :ok
      is_nil(tenant) -> :ok
      true -> check(tenant)
    end
  end

  defp check(tenant) do
    plan = Entitlements.plan_for_project(tenant)

    Entitlements.check(plan, :use_cases_per_project, count(tenant), :plan)
  end

  defp count(tenant) do
    UseCase
    |> Ash.Query.filter(is_nil(archived_at))
    |> Ash.count!(tenant: tenant, actor: PromptOn.SystemActor.new())
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "the plan limit counts existing rows in Elixir, not SQL"}
  end
end
