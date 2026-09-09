defmodule PromptOn.Accounts.Membership.Changes.AssignProjects do
  @moduledoc "Synchronizes project grants for a membership within its organization."

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias PromptOn.Projects
  alias PromptOn.Projects.Project
  alias PromptOn.Repo

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      membership = changeset.data
      project_ids = Ash.Changeset.get_argument(changeset, :project_ids) || []

      with :ok <- validate_project_ids(project_ids),
           {:ok, projects} <- projects_in_organization(project_ids, membership.organization_id),
           :ok <- ensure_all_found(project_ids, projects),
           :ok <- sync_grants(membership, project_ids) do
        changeset
      else
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp validate_project_ids(project_ids) when is_list(project_ids), do: :ok

  defp validate_project_ids(_project_ids),
    do: {:error, invalid(:project_ids, "must be a list of project ids")}

  defp projects_in_organization([], _organization_id), do: {:ok, []}

  defp projects_in_organization(project_ids, organization_id) do
    projects =
      Project
      |> Ash.Query.filter(
        id in ^project_ids and organization_id == ^organization_id and is_nil(archived_at)
      )
      |> Ash.read!(actor: PromptOn.SystemActor.new())

    {:ok, projects}
  end

  defp ensure_all_found(project_ids, projects) do
    found_ids = MapSet.new(projects, & &1.id)

    if Enum.all?(project_ids, &MapSet.member?(found_ids, &1)) do
      :ok
    else
      {:error, invalid(:project_ids, "must all be active projects in the member's organization")}
    end
  end

  defp sync_grants(membership, project_ids) do
    Repo.transaction(fn ->
      delete_removed(membership, project_ids)

      Enum.reduce_while(project_ids, :ok, fn project_id, :ok ->
        case Projects.grant_project_membership(
               %{project_id: project_id, user_id: membership.user_id},
               actor: PromptOn.SystemActor.new()
             ) do
          {:ok, _grant} -> {:cont, :ok}
          {:error, error} -> {:halt, Repo.rollback(error)}
        end
      end)
    end)
    |> case do
      {:ok, _other} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp delete_removed(membership, []) do
    Repo.query!(
      """
      DELETE FROM project_memberships
      WHERE user_id = $1
      AND project_id IN (
        SELECT id FROM projects WHERE organization_id = $2
      )
      """,
      [Ecto.UUID.dump!(membership.user_id), Ecto.UUID.dump!(membership.organization_id)]
    )
  end

  defp delete_removed(membership, project_ids) do
    Repo.query!(
      """
      DELETE FROM project_memberships
      WHERE user_id = $1
      AND project_id IN (
        SELECT id FROM projects WHERE organization_id = $2
      )
      AND project_id <> ALL($3::uuid[])
      """,
      [
        Ecto.UUID.dump!(membership.user_id),
        Ecto.UUID.dump!(membership.organization_id),
        Enum.map(project_ids, &Ecto.UUID.dump!/1)
      ]
    )
  end

  defp invalid(field, message),
    do: InvalidArgument.exception(field: field, message: message)
end
