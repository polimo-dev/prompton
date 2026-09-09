defmodule PromptOn.Accounts.Invitation.Policy do
  @moduledoc false

  alias PromptOn.Accounts.Permissions
  alias PromptOn.Projects.Project

  require Ash.Query

  @spec authorize_invite(term(), String.t(), atom(), [String.t()]) ::
          :ok | {:error, Ash.Error.Changes.InvalidAttribute.t()}
  def authorize_invite(%PromptOn.Accounts.User{} = actor, organization_id, role, project_ids) do
    with :ok <- validate_project_scope(organization_id, project_ids) do
      case {Permissions.role(actor, organization_id), role} do
        {nil, _invited} ->
          {:error, invalid(:organization_id, "is not accessible")}

        {role, _invited} when role in [:owner, :admin] ->
          :ok

        {:member, :member} ->
          validate_member_projects(actor.id, organization_id, project_ids)

        {_other, _invited} ->
          {:error, invalid(:role, "cannot be invited by this user")}
      end
    end
  end

  def authorize_invite(_actor, _organization_id, _role, _project_ids),
    do: {:error, invalid(:actor, "must be a user")}

  defp validate_project_scope(_organization_id, []), do: :ok

  defp validate_project_scope(organization_id, project_ids) do
    projects =
      Project
      |> Ash.Query.filter(id in ^project_ids and organization_id == ^organization_id)
      |> Ash.read!(actor: PromptOn.SystemActor.new())

    found = MapSet.new(projects, & &1.id)

    if Enum.all?(project_ids, &MapSet.member?(found, &1)) do
      :ok
    else
      {:error, invalid(:project_ids, "must all belong to the organization")}
    end
  end

  defp validate_member_projects(_actor_id, _organization_id, []),
    do: {:error, invalid(:project_ids, "must include projects created by this member")}

  defp validate_member_projects(actor_id, organization_id, project_ids) do
    allowed =
      %PromptOn.Accounts.User{id: actor_id}
      |> Permissions.invitable_projects(organization_id)
      |> MapSet.new(& &1.id)

    if Enum.all?(project_ids, &MapSet.member?(allowed, &1)) do
      :ok
    else
      {:error, invalid(:project_ids, "must include only projects created by this member")}
    end
  end

  defp invalid(field, message),
    do: Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)
end
