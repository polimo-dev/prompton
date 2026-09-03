defmodule PromptOn.Accounts.Organization.Validations.SlugNotReserved do
  @moduledoc """
  Checks that an organization slug is not a router reserved word
  (`PromptOn.Accounts.ReservedSlugs`). Passes when there is no slug (personal organization);
  format and length are checked by the attribute constraints.
  """

  use Ash.Resource.Validation

  alias PromptOn.Accounts.ReservedSlugs

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      nil ->
        :ok

      slug ->
        if ReservedSlugs.reserved?(slug) do
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :slug,
             message: "is reserved and cannot be used as an organization slug"
           )}
        else
          :ok
        end
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "reserved-slug lookup runs in Elixir, not SQL"}
  end
end
