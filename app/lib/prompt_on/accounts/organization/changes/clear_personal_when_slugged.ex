defmodule PromptOn.Accounts.Organization.Changes.ClearPersonalWhenSlugged do
  @moduledoc """
  The moment an organization gets a slug it is no longer personal: a personal organization is
  addressed only via `/personal`, without a slug (product decision: personal→team promotion =
  claiming a slug).

  `:claim_slug` is also used to rename team organizations, so if the slug is still nil (= only a
  personal organization's name changed) `personal?` is left untouched.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      nil -> changeset
      _slug -> Ash.Changeset.force_change_attribute(changeset, :personal?, false)
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "depends on the resulting slug value"}
  end
end
