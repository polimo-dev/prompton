defmodule PromptOn.Checks.CanGrantProjectMembership do
  @moduledoc """
  Allows project membership grants/revokes by organization managers or by a member who created the
  project.
  """

  use Ash.Policy.SimpleCheck

  alias PromptOn.Accounts.Permissions
  alias PromptOn.Projects.Project

  require Ash.Query

  @impl true
  def describe(_opts), do: "actor can grant project membership"

  @impl true
  def match?(%PromptOn.Accounts.User{id: actor_id} = actor, %{subject: subject}, _opts) do
    with {:ok, project_id} <- project_id(subject),
         %Project{} = project <- get_project(project_id) do
      Permissions.manage?(actor, project.organization_id) or
        (Permissions.role(actor, project.organization_id) == :member and
           project.creator_id == actor_id and current_project_access?(actor, project_id))
    else
      _other -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp project_id(%Ash.Changeset{} = changeset) do
    case Ash.Changeset.get_attribute(changeset, :project_id) do
      nil -> {:error, :missing_project_id}
      project_id -> {:ok, project_id}
    end
  end

  defp project_id(%{project_id: project_id}) when not is_nil(project_id), do: {:ok, project_id}
  defp project_id(_subject), do: {:error, :missing_project_id}

  defp get_project(project_id) do
    Project
    |> Ash.Query.filter(id == ^project_id)
    |> Ash.read_one!(actor: PromptOn.SystemActor.new())
  end

  defp current_project_access?(actor, project_id) do
    case Ash.get(Project, project_id, actor: actor) do
      {:ok, %Project{}} -> true
      {:ok, nil} -> false
      {:error, _error} -> false
    end
  end
end
