defmodule PromptOn.Accounts.Invitation.Changes.DeliverEmail do
  @moduledoc """
  Sends the invitation email after the row has been inserted.
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts.Invitation.Email
  alias PromptOn.Mailer

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, invitation ->
      token = Ash.Resource.get_metadata(invitation, :token)

      invitation.email
      |> to_string()
      |> Email.build(token)
      |> Mailer.deliver()
      |> case do
        {:ok, _delivered} ->
          {:ok, invitation}

        {:error, _reason} ->
          {:error, delivery_error()}
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
