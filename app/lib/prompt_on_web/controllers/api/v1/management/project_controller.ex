defmodule PromptOnWeb.API.V1.Management.ProjectController do
  @moduledoc """
  `GET /api/v1/orgs/:org/projects` and `POST …` - the projects of the organization the path points
  at.

  ## The address is the slug

  In every sub-path of this API a project is addressed **by slug** (`/projects/:project/...`) - the
  same value as `/{org}/{project}` in the UI. The create request takes that value as `key` (the
  same grain as a use case's `key`, a prompt's `name`, and an environment's slug - a coding AI
  never has to carry UUIDs around). Sending it under the name `slug` works the same.

  Without `name`, `key` is used verbatim. The `production`/`staging` environments are created in
  the same transaction as the project (`Project.Changes.CreateDefaultEnvironments`) - that is what
  the `environments` in the response are.

  Creating with a slug that already exists is **409** with that project in `details.project` - a
  coding AI must be able to move on to the next step even after re-running a provisioning script.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Projects
  alias PromptOn.Projects.Project
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.Params
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  def index(conn, _params) do
    organization = Scope.organization(conn)

    with {:ok, projects} <-
           Projects.list_projects(
             actor: Scope.user(conn),
             query: [filter: [organization_id: organization.id]]
           ) do
      projects = Enum.sort_by(projects, & &1.slug)
      json(conn, %{"projects" => Enum.map(projects, &summary(conn, &1))})
    end
  end

  def create(conn, params) do
    user = Scope.user(conn)
    organization = Scope.organization(conn)

    with {:ok, slug} <- project_key(params),
         {:ok, name} <- Params.optional_string(params, "name"),
         {:ok, timezone} <- Params.optional_string(params, "timezone"),
         :ok <- ensure_available(conn, slug),
         attrs = attrs(organization, slug, name, timezone),
         {:ok, project} <- Projects.create_project(attrs, actor: user) do
      conn |> put_status(:created) |> json(summary(conn, project))
    end
  end

  # ---------------------------------------------------------------------------

  defp project_key(params) do
    case Map.get(params, "key") || Map.get(params, "slug") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:invalid_request, "key is required"}}
    end
  end

  defp attrs(organization, slug, name, timezone) do
    attrs = %{
      organization_id: organization.id,
      slug: slug,
      name: name || slug
    }

    if timezone, do: Map.put(attrs, :timezone, timezone), else: attrs
  end

  defp ensure_available(conn, slug) do
    case Projects.get_project_by_slug(Scope.organization(conn).id, slug, actor: Scope.user(conn)) do
      {:ok, %Project{} = project} ->
        {:error,
         {:conflict, "a project with key #{slug} already exists",
          %{"project" => summary(conn, project)}}}

      _other ->
        :ok
    end
  end

  # Environments are a tenant resource, so every project has a different tenant - the listing reads
  # them once per project as well (as many reads as the organization has projects, and without the
  # environment slugs no deployment pin can be committed).
  defp summary(conn, project), do: JSON.project(project, Scope.environments(conn, project))
end
