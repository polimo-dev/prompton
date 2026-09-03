defmodule PromptOn.Observability.GenerationPayload.Changes.SetExpiresAt do
  @moduledoc "`expires_at = received_at + retention_days` (`:store` argument, default 30 days)."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    received_at = Ash.Changeset.get_attribute(changeset, :received_at) || DateTime.utc_now()
    days = Ash.Changeset.get_argument(changeset, :retention_days) || 30

    changeset
    |> Ash.Changeset.force_change_attribute(:received_at, received_at)
    |> Ash.Changeset.force_change_attribute(:expires_at, DateTime.add(received_at, days, :day))
  end
end
