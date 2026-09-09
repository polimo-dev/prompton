defmodule PromptOn.Accounts.Membership do
  @moduledoc """
  Organization ↔ user. Stored legacy roles (`:editor` / `:viewer`) remain readable during rolling
  deployments; writes accept only `:owner`, `:admin`, and `:member`.
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
      description """
      Creates the owner membership in the sign-up flow (system only). Beyond the first member an
      organization has to be on a paid plan (ADR 0010 §6.4) — see `Validations.WithinPlanLimit`
      for why that does not break sign-up.
      """

      accept [:organization_id, :user_id, :role]
      validate attribute_in(:role, [:owner, :admin, :member])
      validate PromptOn.Accounts.Membership.Validations.WithinPlanLimit
    end

    update :change_role do
      description "Changes a non-owner member's role. Ownership transfer uses Organization.:transfer_ownership."

      accept [:role]
      require_atomic? false
      validate attribute_in(:role, [:admin, :member])
      change PromptOn.Accounts.Membership.Changes.LockOrganizationAndAuthorize
      change PromptOn.Accounts.Membership.Changes.ProtectOwnerMembership
    end

    update :assign_projects do
      description "Replaces the project grants attached to this organization membership."

      argument :project_ids, {:array, :uuid}, allow_nil?: false, default: []
      require_atomic? false
      change PromptOn.Accounts.Membership.Changes.LockOrganizationAndAuthorize
      change PromptOn.Accounts.Membership.Changes.ProtectOwnerMembership
      change PromptOn.Accounts.Membership.Changes.AssignProjects
    end

    destroy :remove do
      description "Removes a member."
      require_atomic? false
      change PromptOn.Accounts.Membership.Changes.LockOrganizationAndAuthorize
      change PromptOn.Accounts.Membership.Changes.ProtectOwnerMembership
      change PromptOn.Accounts.Membership.Changes.RevokeProjectMemberships
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

    policy action(:add) do
      forbid_if always()
    end

    policy action(:change_role) do
      description "Admins can promote existing members; only owners can edit admin rows."
      forbid_if expr(role == :owner)

      authorize_if expr(
                     role in [:member, :editor, :viewer] and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:id) and role in [:owner, :admin]
                       )
                   )

      authorize_if {PromptOn.Checks.OrganizationOwner, path: [:organization]}
    end

    policy action(:remove) do
      description "Admins can remove members, but only owners can remove admins. Owners are never removed directly."
      forbid_if expr(role == :owner)

      authorize_if expr(
                     role in [:member, :editor, :viewer] and
                       exists(
                         organization.memberships,
                         user_id == ^actor(:id) and role in [:owner, :admin]
                       )
                   )

      authorize_if {PromptOn.Checks.OrganizationOwner, path: [:organization]}
    end

    policy action(:assign_projects) do
      description "Organization managers assign project access; owner memberships are not edited directly."
      forbid_if expr(role == :owner)

      authorize_if {PromptOn.Checks.OrganizationManager, path: [:organization]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      default :member
      constraints one_of: [:owner, :admin, :member, :editor, :viewer]
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
