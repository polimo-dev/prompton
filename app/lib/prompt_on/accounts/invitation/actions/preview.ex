defmodule PromptOn.Accounts.Invitation.Actions.Preview do
  @moduledoc """
  Finds a pending invitation by raw token for the signed-in invited user.
  """

  use Ash.Resource.Actions.Implementation

  alias PromptOn.Accounts.Invitation
  alias PromptOn.Projects.Project

  require Ash.Query

  @impl true
  def run(input, _opts, context) do
    token = Ash.ActionInput.get_argument(input, :token)

    with {:ok, invitation} <- find(token),
         :ok <- validate_pending(invitation),
         :ok <- validate_email(invitation, context.actor) do
      load_preview(invitation)
    end
  end

  def find(token) do
    Invitation
    |> Ash.Query.filter(token_hash == ^Invitation.hash(token))
    |> Ash.read_one(actor: PromptOn.SystemActor.new())
    |> case do
      {:ok, %Invitation{} = invitation} -> {:ok, invitation}
      {:ok, nil} -> {:error, invalid(:token, "is not valid")}
      {:error, error} -> {:error, error}
    end
  end

  def validate_pending(invitation) do
    if Invitation.pending?(invitation),
      do: :ok,
      else: {:error, invalid(:token, "is expired, revoked, or already used")}
  end

  def validate_email(invitation, %PromptOn.Accounts.User{} = actor) do
    if String.downcase(to_string(invitation.email)) == String.downcase(to_string(actor.email)),
      do: :ok,
      else: {:error, invalid(:email, "does not match this invitation")}
  end

  def validate_email(_invitation, _actor), do: {:error, invalid(:actor, "must be a user")}

  def load_preview(invitation) do
    with {:ok, invitation} <-
           Ash.load(invitation, [:organization], actor: PromptOn.SystemActor.new()) do
      {:ok, Ash.Resource.put_metadata(invitation, :projects, project_summaries(invitation))}
    end
  end

  defp project_summaries(%Invitation{project_ids: []}), do: []

  defp project_summaries(%Invitation{project_ids: project_ids}) do
    Project
    |> Ash.Query.filter(id in ^project_ids)
    |> Ash.Query.sort(slug: :asc)
    |> Ash.read!(actor: PromptOn.SystemActor.new())
    |> Enum.map(&%{id: &1.id, slug: &1.slug})
  end

  def invalid(field, message),
    do: Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)
end
