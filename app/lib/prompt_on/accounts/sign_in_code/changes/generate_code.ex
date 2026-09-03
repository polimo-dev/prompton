defmodule PromptOn.Accounts.SignInCode.Changes.GenerateCode do
  @moduledoc """
  Creates a new sign-in code and its expiry (`SignInCode.:request`).

  - The code: `SignInCode.generate_code/0` (6 uniform digits). **The raw value is not stored**:
    only `code_hash` (`SignInCode.hash/2`, salted with the row id) is kept, and the raw value
    leaves once as the result record's metadata `:code` (the same pattern as
    `DeviceAuthorization.Changes.GenerateCodes`).
  - The row id is the hash's salt, so it is decided **here**: if we waited for the default
    generator to fill it in at execution time, it would not exist when the changeset is built.
  - `expires_at`: now + `SignInCode.ttl_seconds/0` (5 minutes).
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts.SignInCode

  @impl true
  def change(changeset, _opts, _context) do
    id = Ash.Changeset.get_attribute(changeset, :id) || Ash.UUIDv7.generate()
    code = SignInCode.generate_code()

    changeset
    |> Ash.Changeset.force_change_attribute(:id, id)
    |> Ash.Changeset.force_change_attribute(:code_hash, SignInCode.hash(id, code))
    |> Ash.Changeset.force_change_attribute(
      :expires_at,
      DateTime.add(DateTime.utc_now(), SignInCode.ttl_seconds(), :second)
    )
    |> Ash.Changeset.after_action(fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :code, code)}
    end)
  end
end
