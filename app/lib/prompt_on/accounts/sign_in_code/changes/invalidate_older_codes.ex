defmodule PromptOn.Accounts.SignInCode.Changes.InvalidateOlderCodes do
  @moduledoc """
  **Deletes all previous code rows** for the same address (`before_action` of
  `SignInCode.:request`, same transaction).

  There must be one live code per address: if the old code kept working after "Resend code" was
  clicked, the number of codes an attacker can try would grow by that much. Consumed and expired
  rows are deleted along with it (they are useless anyway; this merely brings forward what the
  sweeper would delete).
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Accounts.SignInCode

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      email = Ash.Changeset.get_attribute(changeset, :email)

      %Ash.BulkResult{status: :success} =
        SignInCode
        |> Ash.Query.filter(email == ^email)
        |> Ash.bulk_destroy!(:destroy, %{},
          actor: PromptOn.SystemActor.new(),
          strategy: [:atomic],
          return_errors?: true
        )

      changeset
    end)
  end
end
