defmodule PromptOn.Checks.ProjectMember do
  @moduledoc """
  Is the User actor a member of the organization that owns the target record's project?
  Every project-scoped (tenant) resource has `belongs_to :project`, so the path is fixed to
  `project.organization.memberships`. `Project` itself uses `path: []`.
  Always false for an ApiKey actor (API key policies use `ApiKeyScope`).
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "actor is a member of the project's organization"

  @impl true
  def filter(%PromptOn.Accounts.User{}, _context, opts) do
    case Keyword.get(opts, :path, [:project]) do
      [] -> expr(exists(organization.memberships, user_id == ^actor(:id)))
      [:project] -> expr(exists(project.organization.memberships, user_id == ^actor(:id)))
    end
  end

  def filter(_actor, _context, _opts), do: false
end
