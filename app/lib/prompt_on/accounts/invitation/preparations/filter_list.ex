defmodule PromptOn.Accounts.Invitation.Preparations.FilterList do
  @moduledoc "Filters invitation lists to invitations that can still be acted on."

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    now = DateTime.utc_now()

    Ash.Query.filter(query, is_nil(accepted_at) and is_nil(revoked_at) and expires_at > ^now)
  end
end
