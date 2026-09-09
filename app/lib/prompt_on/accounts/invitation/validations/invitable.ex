defmodule PromptOn.Accounts.Invitation.Validations.Invitable do
  @moduledoc """
  Validates who may create an invitation and which project ids may be attached.
  """

  use Ash.Resource.Validation

  alias PromptOn.Accounts.Invitation
  alias PromptOn.Accounts.Organization

  @impl true
  def validate(changeset, _opts, context) do
    actor = context.actor

    with {:ok, organization_id} <- required(changeset, :organization_id),
         {:ok, role} <- required(changeset, :role),
         {:ok, project_ids} <- project_ids(changeset),
         :ok <- validate_organization(organization_id) do
      Invitation.Policy.authorize_invite(actor, organization_id, role, project_ids)
    end
  end

  defp validate_organization(organization_id) do
    case Ash.get(Organization, organization_id, actor: PromptOn.SystemActor.new()) do
      {:ok, %Organization{personal?: true}} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :organization_id,
           message:
             "personal organizations cannot invite members. Convert it to a team organization first."
         )}

      {:ok, %Organization{}} ->
        :ok

      _other ->
        :ok
    end
  end

  defp required(changeset, field) do
    case Ash.Changeset.get_attribute(changeset, field) do
      nil ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(field: field, message: "is required")}

      value ->
        {:ok, value}
    end
  end

  defp project_ids(changeset) do
    project_ids = Ash.Changeset.get_attribute(changeset, :project_ids) || []
    {:ok, Enum.uniq(project_ids)}
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "invite authorization reads organization membership and project ownership"}
  end
end
