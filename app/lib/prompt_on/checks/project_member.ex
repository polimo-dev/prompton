defmodule PromptOn.Checks.ProjectMember do
  @moduledoc """
  Is the User actor authorized for the target record's project?

  Owner/admin memberships cover every project in the organization. Member memberships cover only
  projects with a matching `ProjectMembership` row. The organization membership check remains in
  both branches so stale project membership rows cannot leak access after a user is removed from
  the organization.
  Always false for an ApiKey actor (API key policies use `ApiKeyScope`).
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "actor is authorized for the project"

  @impl true
  def filter(%PromptOn.Accounts.User{}, _context, opts) do
    case Keyword.get(opts, :path, [:project]) do
      [] ->
        expr(
          exists(
            organization.memberships,
            user_id == ^actor(:id) and role in [:owner, :admin]
          ) or
            (exists(organization.memberships, user_id == ^actor(:id)) and
               exists(project_memberships, user_id == ^actor(:id)))
        )

      [:project] ->
        expr(
          exists(
            project.organization.memberships,
            user_id == ^actor(:id) and role in [:owner, :admin]
          ) or
            (exists(project.organization.memberships, user_id == ^actor(:id)) and
               exists(project.project_memberships, user_id == ^actor(:id)))
        )
    end
  end

  def filter(_actor, _context, _opts), do: false
end
