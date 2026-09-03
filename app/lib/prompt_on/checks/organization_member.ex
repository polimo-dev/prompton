defmodule PromptOn.Checks.OrganizationMember do
  @moduledoc """
  Is the User actor a member of the target record's organization? (filter check, folded into the
  read query).

  The `path:` option gives the relationship path to the organization.
  - `Organization` itself: `[]` (default) -> `exists(memberships, user_id == actor.id)`
  - `Membership`/`Project`: `[:organization]`
  - Project-scoped (tenant) resources use `PromptOn.Checks.ProjectMember`.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts),
    do: "actor is a member of the organization (via #{inspect(opts[:path] || [])})"

  @impl true
  def filter(%PromptOn.Accounts.User{}, _context, opts) do
    case Keyword.get(opts, :path, []) do
      [] -> expr(exists(memberships, user_id == ^actor(:id)))
      [:organization] -> expr(exists(organization.memberships, user_id == ^actor(:id)))
    end
  end

  def filter(_actor, _context, _opts), do: false
end
