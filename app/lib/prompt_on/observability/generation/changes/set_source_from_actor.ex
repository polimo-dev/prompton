defmodule PromptOn.Observability.Generation.Changes.SetSourceFromActor do
  @moduledoc """
  When the actor is a `%PromptOn.Projects.ApiKey{}`, pins `source` to `:live` (plan.md §5.3, §6.4
  -- a record cannot lie about its origin). Other actors (SystemActor: mix task backfill, the
  arena) use the value they pass.

  The environment no longer comes from the key (2026-09-01 -- an ApiKey is project-scoped and the
  environment is a request parameter): `PromptOn.Observability.Ingest` **forces** the
  `environment_id` it received from the controller **across the whole batch**, so the property
  that a record cannot claim a different environment still holds.
  """

  use Ash.Resource.Change

  alias PromptOn.Projects.ApiKey

  @impl true
  def change(changeset, _opts, %{actor: %ApiKey{}}),
    do: Ash.Changeset.force_change_attribute(changeset, :source, :live)

  def change(changeset, _opts, _context), do: changeset
end
