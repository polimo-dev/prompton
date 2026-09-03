defmodule PromptOn.Accounts.ProviderKey.Changes.BustCache do
  @moduledoc """
  When a key changes (`:register` / `:rotate` / `:revoke`), clears the matching entry in
  `PromptOn.Accounts.ProviderKeyCache`, so the server's LLM calls do not keep using the old key
  for up to a minute (the TTL). The cache entry is deleted only after the request succeeds
  (`after_action`).

  With multiple nodes this hook clears **only its own node's ETS**; other nodes keep using the
  old key for a TTL (the staleness window in the `ProviderKeyCache` module docs).
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts.ProviderKeyCache

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      ProviderKeyCache.invalidate(record.organization_id, record.provider)
      {:ok, record}
    end)
  end
end
