defmodule PromptOn.Accounts.Membership.Changes.ProtectOwnerMembership do
  @moduledoc "Prevents direct owner role changes or removals."

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case changeset.data.role do
        :owner ->
          Ash.Changeset.add_error(
            changeset,
            InvalidAttribute.exception(
              field: :role,
              message: "owner membership is changed through organization ownership transfer"
            )
          )

        _role ->
          changeset
      end
    end)
  end
end
