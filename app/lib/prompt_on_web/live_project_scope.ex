defmodule PromptOnWeb.LiveProjectScope do
  @moduledoc """
  The LiveView organization/project scope `on_mount` hook. Every screen needs the same assigns to
  draw the sidebar.

  The URL is `/{org_slug}/{project_slug}/...`. One hook resolves both segments together:

  - `/:org_slug` (organization home) → `@organization @org_slug @projects`; `@project` is nil.
  - `/:org_slug/:project_slug/...` → the above plus `@project` and `@envs` (sorted by position).

  ## `@org_slug` is **the raw path segment**

  `personal` is not an organization's slug but a reserved segment meaning "the current user's
  personal organization" (`PromptOn.Accounts.ReservedSlugs`). So, independently of the organization
  record, this hook puts **the incoming segment as is** into `@org_slug`: the links a screen builds
  must keep the viewer's addressing (`/personal/...`) for the personal organization (which has no
  slug) to be linkable at all.

  ## Resolution rules

  - `personal` → `Accounts.personal_organization_for(current_user)`. Being a reserved segment it
    **does not go through** `get_organization_by_slug/2` (a team organization cannot have this
    slug).
  - Anything else → `Accounts.get_organization_by_slug/2`. The read policy is an organization
    member filter, so **to a non-member it is as if it did not exist**: when not found, the user is
    sent back to `/personal` with a flash (existence is not leaked).
  - The project is looked up **inside the organization** (project slugs are unique per
    organization). When not found, back to the organization home.

  Authorization is enforced by the Ash policies; this hook only carries the outcome into screen
  assigns.

  Common assigns:

  | assign | meaning |
  |---|---|
  | `@organization` | the current organization |
  | `@organizations` | every organization the user is a member of (sidebar switch list, personal organization first) |
  | `@org_slug` | the raw path segment (`"personal"` or a team organization slug), used to build links |
  | `@project` | the current project (nil on the organization home) |
  | `@projects` | the projects of **this organization** (switcher, with `:use_case_count` metadata) |
  | `@envs` | the project's environments (sorted by position) |
  """

  use PromptOnWeb, :verified_routes

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias PromptOn.Accounts
  alias PromptOn.Projects

  @personal "personal"

  @doc "The reserved path segment that points at the personal organization."
  @spec personal_segment() :: String.t()
  def personal_segment, do: @personal

  @doc false
  def on_mount(:default, params, _session, socket) do
    user = socket.assigns[:current_user]
    org_slug = params["org_slug"]

    case resolve_organization(org_slug, user) do
      {:ok, organization} ->
        mount_organization(socket, org_slug, organization, user, params["project_slug"])

      :error ->
        {:halt,
         socket
         |> put_flash(:error, "Organization not found: #{org_slug}")
         |> redirect(to: not_found_path(org_slug))}
    end
  end

  # When `/personal` itself does not resolve (no personal organization = a broken session), sending
  # the user back to `/personal` would be a redirect loop; only then go to sign-in.
  defp not_found_path(@personal), do: ~p"/sign-in"
  defp not_found_path(_org_slug), do: ~p"/#{@personal}"

  defp resolve_organization(_slug, nil), do: :error

  defp resolve_organization(@personal, user) do
    case Accounts.personal_organization_for(user.id, actor: user) do
      {:ok, %{} = organization} -> {:ok, organization}
      _other -> :error
    end
  end

  defp resolve_organization(slug, user) when is_binary(slug) do
    case Accounts.get_organization_by_slug(slug, actor: user) do
      {:ok, %{} = organization} -> {:ok, organization}
      _other -> :error
    end
  end

  defp resolve_organization(_slug, _user), do: :error

  defp mount_organization(socket, org_slug, organization, user, project_slug) do
    projects = list_projects(organization, user)

    socket =
      assign(socket,
        organization: organization,
        organizations: list_organizations(user),
        org_slug: org_slug,
        project: nil,
        projects: projects,
        envs: []
      )

    mount_project(socket, org_slug, projects, user, project_slug)
  end

  defp mount_project(socket, _org_slug, _projects, _user, nil), do: {:cont, socket}

  # A project slug is unique **only within the organization**, so look it up in the list already
  # narrowed to the organization (a project with the same slug in another organization is not
  # here).
  defp mount_project(socket, org_slug, projects, user, project_slug) do
    case Enum.find(projects, &(&1.slug == project_slug)) do
      nil ->
        {:halt,
         socket
         |> put_flash(:error, "Project not found: #{project_slug}")
         |> redirect(to: ~p"/#{org_slug}")}

      project ->
        envs = list_environments(project, user)

        {:cont, assign(socket, project: project, envs: envs)}
    end
  end

  @doc """
  The **switch list** of the sidebar organization menu: every organization the user is a member
  of. The domain does the sorting (the `:for_user` action: personal organization first, then by
  name). The sidebar must stay alive even on failure, so it falls back to an empty list.
  """
  @spec list_organizations(map() | nil) :: [map()]
  def list_organizations(nil), do: []

  def list_organizations(user) do
    case Accounts.list_organizations_for(user.id, actor: user) do
      {:ok, organizations} -> organizations
      {:error, _error} -> []
    end
  end

  @doc "The (unarchived) projects the user can see inside the organization."
  @spec list_projects(map() | nil, map() | nil) :: [map()]
  def list_projects(nil, _user), do: []
  def list_projects(_organization, nil), do: []

  def list_projects(organization, user) do
    case Projects.list_projects(
           actor: user,
           query: [filter: [organization_id: organization.id]]
         ) do
      {:ok, projects} -> projects |> Enum.sort_by(& &1.slug) |> with_use_case_counts()
      {:error, _} -> []
    end
  end

  # The switcher row's `{n} uc` (mockup `sidebar.jsx`). UseCase is a tenant resource, so reading it
  # per project would cost **every screen** one extra query per project; instead, count in one go
  # over the project ids the policy already filtered and attach the count as metadata. On failure
  # draw without counts (the sidebar must not die).
  defp with_use_case_counts([]), do: []

  defp with_use_case_counts(projects) do
    counts = use_case_counts(Enum.map(projects, & &1.id))

    Enum.map(projects, fn project ->
      Ash.Resource.put_metadata(project, :use_case_count, Map.get(counts, project.id, 0))
    end)
  end

  defp use_case_counts(ids) do
    case PromptOn.Repo.query(
           """
           SELECT project_id::text, count(*)
           FROM use_cases
           WHERE project_id = ANY($1) AND archived_at IS NULL
           GROUP BY project_id
           """,
           [Enum.map(ids, &Ecto.UUID.dump!/1)]
         ) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [id, count] -> {id, count} end)
      _other -> %{}
    end
  rescue
    _ -> %{}
  end

  @doc "The project's environments (archived excluded, sorted by position then slug)."
  @spec list_environments(map(), map()) :: [map()]
  def list_environments(project, user) do
    case Projects.list_environments(tenant: project.id, actor: user) do
      {:ok, envs} -> Enum.sort_by(envs, &{&1.position, &1.slug})
      {:error, _} -> []
    end
  end
end
