defmodule PromptOn.Accounts.Invitation.Changes.GenerateToken do
  @moduledoc """
  Adds a seven-day expiry and stores only a hash of a cryptorandom invitation token.
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts.Invitation

  @impl true
  def change(changeset, _opts, _context) do
    raw = Invitation.generate_token()

    changeset
    |> Ash.Changeset.force_change_attribute(:token_hash, Invitation.hash(raw))
    |> Ash.Changeset.force_change_attribute(
      :expires_at,
      DateTime.add(DateTime.utc_now(), Invitation.ttl_seconds(), :second)
    )
    |> Ash.Changeset.after_action(fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :token, raw)}
    end)
  end
end
