defmodule PromptOn.Projects.Project do
  @moduledoc """
  One app = one tenant (`project_id`). The owning unit of environments, API keys, use cases and the
  model catalog (plan.md §5.4). The default raw-payload storage policy (`payload_policy`) lives here
  too. It is a resource outside the tenant (it is itself the tenant boundary).

  Context dimensions (`dimensions`) were **deleted** (2026-09-01): once Deployment turned from a
  rule router into a pin, their only consumer disappeared. Request context survives only as the
  `Generation.context` log field.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "projects"
    repo PromptOn.Repo

    references do
      reference :organization, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "Create a project and its default `production`/`staging` envs in one transaction."
      accept [:organization_id, :name, :slug, :timezone, :payload_policy]
      validate PromptOn.Projects.Project.Validations.SlugNotReserved
      validate PromptOn.Projects.Project.Validations.WithinPlanLimit
      change PromptOn.Projects.Project.Changes.CreateDefaultEnvironments
    end

    update :rename do
      accept [:name]
    end

    update :set_payload_policy do
      require_atomic? false
      accept [:payload_policy]
    end

    update :archive do
      description "Soft archive. Snapshots and the API do not serve archived projects."
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    read :by_slug do
      argument :organization_id, :uuid, allow_nil?: false
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(organization_id == ^arg(:organization_id) and slug == ^arg(:slug))
    end

    read :active do
      filter expr(is_nil(archived_at))
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass [PromptOn.Checks.ApiKeyActor, action_type(:read)] do
      description "An ApiKey actor reads only its own project (for snapshot assembly)."
      authorize_if expr(id == ^actor(:project_id))
    end

    policy [PromptOn.Checks.ApiKeyActor, action_type([:create, :update, :destroy])] do
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if {PromptOn.Checks.ProjectMember, path: []}
    end

    policy action_type(:create) do
      description "Only organization members create projects in that organization."
      authorize_if relates_to_actor_via([:organization, :memberships, :user])
    end

    policy action_type(:update) do
      authorize_if {PromptOn.Checks.ProjectMember, path: []}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true

    attribute :slug, :string do
      description """
      The second segment of `/{org_slug}/{project_slug}`. Unique within the organization, and it
      must not collide with the organization-scoped static routes (`Validations.SlugNotReserved` ->
      `PromptOn.Accounts.ReservedSlugs.project_reserved?/1`).
      """

      allow_nil? false
      public? true
      constraints match: ~r/^[a-z0-9][a-z0-9-]{0,62}$/
    end

    attribute :timezone, :string, allow_nil?: false, public?: true, default: "Etc/UTC"

    attribute :payload_policy, PromptOn.Observability.PayloadPolicy do
      allow_nil? false
      public? true
      default &PromptOn.Observability.PayloadPolicy.default/0
    end

    attribute :archived_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, PromptOn.Accounts.Organization do
      allow_nil? false
      public? true
    end

    has_many :environments, PromptOn.Projects.Environment do
      public? true
    end

    has_many :api_keys, PromptOn.Projects.ApiKey do
      public? true
    end
  end

  calculations do
    calculate :archived?, :boolean, expr(not is_nil(archived_at))
  end

  aggregates do
    count :environment_count, :environments do
      filter expr(is_nil(archived_at))
    end
  end

  identities do
    identity :unique_slug_per_org, [:organization_id, :slug]
  end
end
