defmodule PromptOn.Accounts.DeviceAuthorization.Changes.GenerateCodes do
  @moduledoc """
  Creates the two codes and the expiry of a device authorization request.

  - `device_code`: URL-safe base64 of 32 random bytes (256 bits). **The raw value is not
    stored**: only `device_code_hash` (sha256 hex) is kept, and the raw value leaves once as the
    result record's metadata `:device_code` (the same pattern as
    `PromptOn.Projects.ApiKey.Changes.GenerateKey`).
  - `user_code`: the human-readable `XXXX-XXXX`. There is a unique index, so if it collides with a
    live code we redraw a few times (26-character alphabet × 8 positions, so in practice this
    almost never happens).
  - `expires_at`: now + `ttl_seconds/0` (15 minutes).
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Accounts.DeviceAuthorization

  # Collisions are practically nonexistent, but when one happens we redraw a few times instead of
  # failing the request with a unique violation.
  @attempts 5

  @impl true
  def change(changeset, _opts, _context) do
    raw = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    changeset
    |> Ash.Changeset.force_change_attribute(:device_code_hash, DeviceAuthorization.hash(raw))
    |> Ash.Changeset.force_change_attribute(:user_code, unused_user_code())
    |> Ash.Changeset.force_change_attribute(
      :expires_at,
      DateTime.add(DateTime.utc_now(), DeviceAuthorization.ttl_seconds(), :second)
    )
    |> Ash.Changeset.after_action(fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :device_code, raw)}
    end)
  end

  defp unused_user_code(attempts \\ @attempts) do
    code = DeviceAuthorization.generate_user_code()

    if attempts > 1 and taken?(code), do: unused_user_code(attempts - 1), else: code
  end

  defp taken?(code) do
    DeviceAuthorization
    |> Ash.Query.filter(user_code == ^code)
    |> Ash.exists?(authorize?: false)
  end
end
