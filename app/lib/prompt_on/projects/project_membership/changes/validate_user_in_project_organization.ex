defmodule PromptOn.Projects.ProjectMembership.Changes.ValidateUserInProjectOrganization do
  @moduledoc "Requires the granted user to be a member of the project's organization."

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias PromptOn.Accounts.Membership
  alias PromptOn.Projects.Project

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      project_id = Ash.Changeset.get_attribute(changeset, :project_id)
      user_id = Ash.Changeset.get_attribute(changeset, :user_id)

      if organization_member?(project_id, user_id) do
        changeset
      else
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(
            field: :user_id,
            message: "must be a member of the project's organization"
          )
        )
      end
    end)
  end

  defp organization_member?(project_id, user_id)
       when is_binary(project_id) and is_binary(user_id) do
    with %Project{organization_id: organization_id} <- project(project_id),
         %Membership{} <- membership(organization_id, user_id) do
      true
    else
      _other -> false
    end
  end

  defp organization_member?(_project_id, _user_id), do: false

  defp project(project_id) do
    Project
    |> Ash.Query.filter(id == ^project_id)
    |> Ash.read_one!(actor: PromptOn.SystemActor.new())
  end

  defp membership(organization_id, user_id) do
    Membership
    |> Ash.Query.filter(organization_id == ^organization_id and user_id == ^user_id)
    |> Ash.read_one!(actor: PromptOn.SystemActor.new())
  end
end
