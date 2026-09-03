defmodule PromptOn.Projects.Project.Validations.SlugNotReserved do
  @moduledoc """
  Checks that the project slug is not one of the organization-scoped router's reserved words
  (`PromptOn.Accounts.ReservedSlugs.project_reserved?/1`).

  Because URLs are `/{org_slug}/{project_slug}/...`, project slugs share a slot with the
  organization pages (`/{org}/settings`, `/{org}/members`, `/{org}/usage`, ...). Without the
  reservation, creating a project named `settings` would immediately shadow that organization's
  settings screen. The list differs from the organization-slug reserved words (`reserved?/1` covers
  the top-level slot), so the check is separate as well.
  """

  use Ash.Resource.Validation

  alias PromptOn.Accounts.ReservedSlugs

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      nil ->
        :ok

      slug ->
        if ReservedSlugs.project_reserved?(slug) do
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :slug,
             message: "is reserved and cannot be used as a project slug"
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
