defmodule PromptOn.Checks.OrganizationOwner do
  @moduledoc """
  True when a user has the owner role in the target record's organization.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts),
    do: "actor is the owner of the organization (via #{inspect(opts[:path] || [])})"

  @impl true
  def filter(%PromptOn.Accounts.User{}, _context, opts) do
    case Keyword.get(opts, :path, []) do
      [] ->
        expr(exists(memberships, user_id == ^actor(:id) and role == :owner))

      [:organization] ->
        expr(exists(organization.memberships, user_id == ^actor(:id) and role == :owner))

      [:project, :organization] ->
        expr(exists(project.organization.memberships, user_id == ^actor(:id) and role == :owner))
    end
  end

  def filter(_actor, _context, _opts), do: false
end
