defmodule PromptOn.Checks.ApiKeyScope do
  @moduledoc """
  Is the actor a `%PromptOn.Projects.ApiKey{}` holding the required scope (`:read` | `:logs`)?
  Tenant (project_id) matching is enforced by multitenancy; environment matching by each resource's
  filter policy.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "api key has scope #{inspect(opts[:scope])}"

  @impl true
  def match?(%PromptOn.Projects.ApiKey{scopes: scopes}, _context, opts) do
    Keyword.fetch!(opts, :scope) in (scopes || [])
  end

  def match?(_, _, _), do: false
end
