defmodule PromptOn.Accounts.Organization do
  @moduledoc """
  The owning unit of projects. Not the tenant (the tenant is `project_id`, plan.md §5.3).
  The one policy is "is the actor a member of the owning organization".

  URLs are `/{org_slug}/{project_slug}/...`. There are two kinds of organization:

  - **Personal organization** (`personal?: true`, `slug: nil`): created automatically, one per
    user, at sign-up. It has no slug, so it is addressed by the reserved segment `/personal`
    (= the current user's personal organization). Users themselves have no slug.
  - **Team organization** (`personal?: false`, `slug` required): lives at `/{slug}` under a
    globally unique slug. Reserved words (`PromptOn.Accounts.ReservedSlugs`) collide with the
    router's static paths, so they are rejected.

  Personal→team promotion is `:claim_slug` (the moment it gets a slug, `personal?` is switched
  off). Team organization creation is in the UI (`/{org}?new_org=1`); invitations do not exist
  yet.

  The organization also carries the **entitlement tier** `plan` (`:free | :team | :pro`, ADR
  0010 §2.8). It is written only by `:set_plan`, which nothing but the `SystemActor` may run, and
  it is read exclusively through `PromptOn.Entitlements` — no call site turns a plan into a number
  on its own.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "organizations"
    repo PromptOn.Repo

    # slug is nullable (personal organizations have none) → uniqueness is a **partial index**.
    # ash_postgres has no way to translate the `where` of `identity :unique_slug` below into SQL,
    # so it is spelled out here.
    identity_wheres_to_sql unique_slug: "slug IS NOT NULL"
  end

  actions do
    defaults [:read]

    create :create do
      description """
      Creates a team organization; name + slug required. Any signed-in user can create one
      (2026-09-01, organization creation UI), and the creator becomes the first owner member
      (`Changes.AddCreatorAsOwner`).
      """

      accept [:name, :slug]
      validate present(:slug), message: "is required for a team organization"
      validate PromptOn.Accounts.Organization.Validations.SlugNotReserved
      validate PromptOn.Accounts.Organization.Validations.TeamOrganizationsAllowed
      change set_attribute(:personal?, false)
      change PromptOn.Accounts.Organization.Changes.AddCreatorAsOwner
    end

    create :create_personal do
      description """
      The personal organization of the sign-up flow: no slug (resolved via `/personal`). System
      only.
      """

      accept [:name]
      change set_attribute(:slug, nil)
      change set_attribute(:personal?, true)
    end

    update :rename do
      accept [:name]
    end

    update :set_plan do
      description """
      Sets the entitlement tier. **System actor only** — the private admin app (and
      `mix prompton.set_plan`) flips it; there is no billing and no self-serve change
      (ADR 0010 §2.8).
      """

      accept [:plan]
    end

    update :set_judge_model do
      description """
      The organization's default judge model for evals. `nil` falls back to
      `config :prompton, :judge_model`. Members set it from organization settings.
      """

      accept [:judge_model]
    end

    update :claim_slug do
      description """
      Claims a slug. This is the path by which a personal organization is promoted to a team
      organization (at that moment `personal?` is switched off), and the path by which a team
      organization changes its slug/name. Reserved words, format, and global uniqueness must all
      pass.
      """

      require_atomic? false
      accept [:slug, :name]
      validate PromptOn.Accounts.Organization.Validations.SlugNotReserved
      change PromptOn.Accounts.Organization.Changes.ClearPersonalWhenSlugged
    end

    read :by_slug do
      description """
      Finds **team organizations only** by slug. Personal organizations have no slug and resolve
      via `/personal`.
      """

      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(personal? == false and slug == ^arg(:slug))
    end

    read :personal_for_user do
      description """
      The user's personal organization (for resolving `/personal`). One is created at sign-up.
      """

      argument :user_id, :uuid, allow_nil?: false
      get? true
      filter expr(personal? == true and exists(memberships, user_id == ^arg(:user_id)))
    end

    read :for_user do
      description """
      All organizations the user is a member of (for the organization switcher). Personal first.
      """

      argument :user_id, :uuid, allow_nil?: false
      prepare build(sort: [personal?: :desc, name: :asc])
      filter expr(exists(memberships, user_id == ^arg(:user_id)))
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      description "Only members see their organization."
      authorize_if PromptOn.Checks.OrganizationMember
    end

    policy action(:set_plan) do
      description "Plans are not self-serve: only the SystemActor bypass above gets through."
      forbid_if always()
    end

    policy action([:rename, :claim_slug, :set_judge_model]) do
      authorize_if PromptOn.Checks.OrganizationMember
    end

    policy action(:create) do
      description """
      Any signed-in user creates team organizations (the creator becomes an owner member).
      The public API's ApiKey actor cannot create organizations.
      """

      forbid_if PromptOn.Checks.ApiKeyActor
      authorize_if actor_present()
    end

    policy action(:create_personal) do
      description "Personal organizations are for the sign-up flow (system) only: one per user."
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true

    attribute :slug, :string do
      description """
      The globally unique URL segment of a team organization. nil for personal organizations.
      """

      allow_nil? true
      public? true
      constraints match: ~r/^[a-z0-9][a-z0-9-]*$/, min_length: 2, max_length: 40
    end

    attribute :personal?, :boolean do
      description """
      Whether this is the personal organization created automatically at sign-up. Personal
      organizations live at `/personal` without a slug.
      """

      allow_nil? false
      public? true
      default false
    end

    attribute :plan, :atom do
      description """
      Entitlement tier. Set by the system actor only (the private admin app /
      `mix prompton.set_plan`) — there is no billing and no self-serve change.
      `PromptOn.Entitlements` is the single place that turns this value into limits.
      """

      allow_nil? false
      public? true
      default :free
      constraints one_of: [:free, :team, :pro]
    end

    attribute :judge_model, :string do
      description """
      Organization default judge model for evals (ADR 0010 §4.4). nil falls back to
      `config :prompton, :judge_model`.
      """

      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :memberships, PromptOn.Accounts.Membership do
      public? true
    end

    has_many :projects, PromptOn.Projects.Project do
      public? true
    end
  end

  identities do
    # Unique only among rows that have a slug (partial index; see `identity_wheres_to_sql` above).
    identity :unique_slug, [:slug] do
      where expr(not is_nil(slug))
    end
  end
end
