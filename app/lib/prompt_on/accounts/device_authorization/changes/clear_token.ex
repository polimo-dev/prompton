defmodule PromptOn.Accounts.DeviceAuthorization.Changes.ClearToken do
  @moduledoc """
  Erases the token ciphertext of a consumed request (`:consume`).

  `token` is a value AshCloak put into `encrypted_token`, so here we **clear the ciphertext column
  directly**: re-encrypting `nil` into it would leave behind "ciphertext that decrypts to nil"
  and storage would not shrink.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.force_change_attribute(changeset, :encrypted_token, nil)
end
