defmodule PromptOn.Accounts.ProviderKey.Changes.SetSecretHint do
  @moduledoc """
  Builds the plaintext display value `secret_hint` from the raw `secret` (`ProviderKey.hint/1`).

  `AshCloak` turns `accept [:secret]` into an **argument** and stores it encrypted in
  `encrypted_secret`, so this change reads the argument rather than the attribute too. A missing
  or blank argument is blocked here; left alone, `:rotate` would encrypt and store `nil` and
  silently break the key.
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts.ProviderKey

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :secret) do
      {:ok, secret} when is_binary(secret) ->
        case ProviderKey.hint(secret) do
          nil -> blank_error(changeset)
          hint -> Ash.Changeset.force_change_attribute(changeset, :secret_hint, hint)
        end

      _ ->
        blank_error(changeset)
    end
  end

  defp blank_error(changeset) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidAttribute.exception(
        field: :secret,
        message: "must be present"
      )
    )
  end
end
