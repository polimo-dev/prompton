defmodule PromptOn.Projects.ApiKey.Preparations.FilterByRawKey do
  @moduledoc "sha256 the raw key, then filter on `key_hash` match + not revoked + not expired."

  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    hash = query |> Ash.Query.get_argument(:raw_key) |> PromptOn.Projects.ApiKey.hash()

    Ash.Query.filter(
      query,
      key_hash == ^hash and is_nil(revoked_at) and (is_nil(expires_at) or expires_at > now())
    )
  end
end
