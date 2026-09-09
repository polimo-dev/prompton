defmodule PromptOn.Accounts.Invitation.Changes.DeliverEmail do
  @moduledoc """
  Sends the invitation email after the row has been inserted.
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts.Invitation.Email
  alias PromptOn.Accounts.Organization
  alias PromptOn.Mailer

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    Ash.Changeset.after_action(changeset, fn _changeset, invitation ->
      token = Ash.Resource.get_metadata(invitation, :token)

      with {:ok, organization} <-
             Ash.get(Organization, invitation.organization_id, actor: actor),
           {:ok, _delivered} <-
             invitation.email
             |> to_string()
             |> Email.build(token, organization.name, to_string(actor.email))
             |> Mailer.deliver() do
        {:ok, invitation}
      else
        {:error, _reason} -> {:error, delivery_error()}
      end
    end)
  end

  defp delivery_error,
    do:
      Ash.Error.Changes.InvalidAttribute.exception(
        field: :email,
        message: "Could not send invitation email. Try again."
      )
end
