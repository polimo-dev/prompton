defmodule PromptOn.Accounts.Permissions do
  @moduledoc """
  Role helpers for organization and project authorization.

  Stored legacy roles (`:editor` / `:viewer`) are readable during rolling deploys, but are treated
  as `:member` for every permission decision.
  """

  alias PromptOn.Accounts.Membership
  alias PromptOn.Projects.Project

  require Ash.Query

  @type normalized_role :: :owner | :admin | :member

  @doc "Returns the actor's normalized role in an organization, or nil when they are not a member."
  @spec role(PromptOn.Accounts.User.t() | nil, Ash.UUID.t()) :: normalized_role() | nil
  def role(%PromptOn.Accounts.User{id: user_id}, organization_id) do
    case membership(user_id, organization_id) do
      %Membership{role: role} -> normalize_role(role)
      nil -> nil
    end
  end

  def role(_actor, _organization_id), do: nil

  @doc "True when the actor can manage organization-wide settings and membership."
  @spec manage?(PromptOn.Accounts.User.t() | nil, Ash.UUID.t()) :: boolean()
  def manage?(actor, organization_id), do: role(actor, organization_id) in [:owner, :admin]

  @doc "True when the actor is the organization owner."
  @spec owner?(PromptOn.Accounts.User.t() | nil, Ash.UUID.t()) :: boolean()
  def owner?(actor, organization_id), do: role(actor, organization_id) == :owner

  @doc """
  Projects the actor may invite members into.

  Owners and admins can invite into every active project in the organization. Members can invite
  only into active projects they created.
  """
  @spec invitable_projects(PromptOn.Accounts.User.t() | nil, Ash.UUID.t()) :: [Project.t()]
  def invitable_projects(%PromptOn.Accounts.User{id: user_id} = actor, organization_id) do
    case role(actor, organization_id) do
      role when role in [:owner, :admin] ->
        organization_projects(organization_id)

      :member ->
        actor
        |> authorized_projects(organization_id)
        |> Enum.filter(&(&1.creator_id == user_id))

      _other ->
        []
    end
  end

  def invitable_projects(_actor, _organization_id), do: []

  @doc false
  @spec normalize_role(atom() | nil) :: normalized_role() | nil
  def normalize_role(role) when role in [:owner, :admin, :member], do: role
  def normalize_role(role) when role in [:editor, :viewer], do: :member
  def normalize_role(_role), do: nil

  defp membership(user_id, organization_id) do
    Membership
    |> Ash.Query.filter(user_id == ^user_id and organization_id == ^organization_id)
    |> Ash.read_one!(actor: PromptOn.SystemActor.new())
  end

  defp organization_projects(organization_id) do
    Project
    |> Ash.Query.filter(organization_id == ^organization_id and is_nil(archived_at))
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(actor: PromptOn.SystemActor.new())
  end

  defp authorized_projects(actor, organization_id) do
    Project
    |> Ash.Query.filter(organization_id == ^organization_id and is_nil(archived_at))
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(actor: actor)
  end
end
