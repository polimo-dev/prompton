defmodule PromptOn.Checks.OrganizationManager do
  @moduledoc """
  True when a user has the owner or admin role in the target record's organization.
  """

  use Ash.Policy.FilterCheck

  @manager_roles [:owner, :admin]

  @impl true
  def describe(opts),
    do: "actor is an owner/admin of the organization (via #{inspect(opts[:path] || [])})"

  @impl true
  def filter(%PromptOn.Accounts.User{}, _context, opts) do
    case Keyword.get(opts, :path, []) do
      [] ->
        expr(exists(memberships, user_id == ^actor(:id) and role in ^@manager_roles))

      [:organization] ->
        expr(exists(organization.memberships, user_id == ^actor(:id) and role in ^@manager_roles))

      [:project, :organization] ->
        expr(
          exists(
            project.organization.memberships,
            user_id == ^actor(:id) and role in ^@manager_roles
          )
        )
    end
  end

  def filter(_actor, _context, _opts), do: false
end
