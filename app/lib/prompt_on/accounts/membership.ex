defmodule PromptOn.Accounts.Membership do
  @moduledoc """
  Organization ↔ user. In P0 `role` is only stored; policies do not branch on it (plan.md §5.4).
  Invitations (`:invite`) and role changes (`:change_role`) are P2.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "memberships"
    repo PromptOn.Repo

    references do
      reference :organization, on_delete: :delete
      reference :user, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :add do
      description "Creates the owner membership in the sign-up flow (system only)."
      accept [:organization_id, :user_id, :role]
    end

    destroy :remove do
      description "Removes a member. No UI in P0 (comes with P2 member management)."
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      description "One's own membership, or the membership of a member of the same organization."
      authorize_if expr(user_id == ^actor(:id))
      authorize_if {PromptOn.Checks.OrganizationMember, path: [:organization]}
    end

    policy action_type([:create, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      default :owner
      constraints one_of: [:owner, :admin, :editor, :viewer]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, PromptOn.Accounts.Organization do
      allow_nil? false
      public? true
    end

    belongs_to :user, PromptOn.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_member, [:organization_id, :user_id]
  end
end
