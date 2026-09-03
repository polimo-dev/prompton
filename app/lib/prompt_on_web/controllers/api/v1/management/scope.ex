defmodule PromptOnWeb.API.V1.Management.Scope do
  @moduledoc """
  Shared by the management API controllers - **resolves the actor and tenant on every request**.

  The actor is the **user** a CLI session token points at (`PromptOnWeb.Plugs.UserTokenAuth`). The
  organization has already been resolved from the path's `:org` segment by
  `PromptOnWeb.Plugs.ManagementOrgScope` into `conn.assigns.organization`. What remains, for
  requests that touch project-scoped (tenant) resources, is to resolve the path's `:project`
  segment (= the project slug) into `[tenant: project.id, actor: user]`.

  **Outside the organization nothing exists**: the project lookup is pinned to the organization the
  path chose, so another organization's slug is **404**, not 403 (it does not reveal what that
  organization contains). An archived project is 404 for the same reason - the same rule as a
  runtime key getting 401 on an archived project.
  """

  alias PromptOn.Accounts.Organization
  alias PromptOn.Accounts.User
  alias PromptOn.Projects
  alias PromptOn.Projects.Environment
  alias PromptOn.Projects.Project
  alias PromptOn.Prompts
  alias PromptOn.Prompts.UseCase

  @default_environment "production"

  @doc "The request's actor - the user the CLI session token points at."
  @spec user(Plug.Conn.t()) :: User.t()
  def user(conn), do: conn.assigns.current_user

  @doc "The organization the path's `:org` points at (already resolved by the plug)."
  @spec organization(Plug.Conn.t()) :: Organization.t()
  def organization(conn), do: conn.assigns.organization

  @doc "Path segment `:project` (project slug) -> a live project of this organization."
  @spec fetch_project(Plug.Conn.t(), map()) :: {:ok, Project.t()} | {:error, term()}
  def fetch_project(conn, %{"project" => slug}) when is_binary(slug) and slug != "" do
    actor = user(conn)

    case Projects.get_project_by_slug(organization(conn).id, slug, actor: actor) do
      {:ok, %Project{archived_at: nil} = project} ->
        {:ok, project}

      _other ->
        {:error, {:not_found, "unknown project: #{slug}", %{"project" => slug}}}
    end
  end

  def fetch_project(_conn, _params),
    do: {:error, {:invalid_request, "project is required"}}

  @doc "Call options for project-scoped resources."
  @spec scope(Plug.Conn.t(), Project.t()) :: keyword()
  def scope(conn, %Project{} = project), do: [tenant: project.id, actor: user(conn)]

  @doc """
  Path segment `:key` (use case key) -> a live use case of this project. An archived use case is
  404 - provisioning touches only live contracts.
  """
  @spec fetch_use_case(keyword(), map()) :: {:ok, UseCase.t()} | {:error, term()}
  def fetch_use_case(scope, %{"key" => key}) when is_binary(key) and key != "" do
    case Prompts.get_use_case_by_key(key, scope) do
      {:ok, %UseCase{archived_at: nil} = use_case} ->
        {:ok, use_case}

      _other ->
        {:error, {:not_found, "unknown use case: #{key}", %{"use_case" => key}}}
    end
  end

  def fetch_use_case(_scope, _params),
    do: {:error, {:invalid_request, "use case key is required"}}

  @doc "The project's live environments (in position order)."
  @spec environments(Plug.Conn.t(), Project.t()) :: [Environment.t()]
  def environments(conn, project) do
    case Projects.list_environments(scope(conn, project)) do
      {:ok, envs} -> Enum.sort_by(envs, &{&1.position, &1.slug})
      {:error, _error} -> []
    end
  end

  @doc """
  The environment the request chose. `"production"` when `params["environment"]` is absent (the
  same default as the public API).
  """
  @spec fetch_environment(Plug.Conn.t(), Project.t(), map()) ::
          {:ok, Environment.t()} | {:error, term()}
  def fetch_environment(conn, project, params) do
    with {:ok, slug} <- environment_slug(params) do
      case Enum.find(environments(conn, project), &(&1.slug == slug)) do
        %Environment{} = environment ->
          {:ok, environment}

        nil ->
          {:error, {:not_found, "unknown environment: #{slug}", %{"environment" => slug}}}
      end
    end
  end

  @doc "The default environment slug."
  @spec default_environment() :: String.t()
  def default_environment, do: @default_environment

  defp environment_slug(params) do
    case Map.get(params, "environment") do
      nil -> {:ok, @default_environment}
      slug when is_binary(slug) and slug != "" -> {:ok, slug}
      _other -> {:error, {:invalid_request, "environment must be a non-empty string"}}
    end
  end
end
