defmodule PromptOn.Projects.Environment do
  @moduledoc """
  Deployment target separation (`production`, `staging`, ...). Deployments are per env, and an
  ApiKey belongs to an env (plan.md §5.4). The `:config_snapshot` generic action (snapshot assembly)
  is filled in by the Deployments domain: `PromptOn.Deployments.Snapshot`.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Projects,
    fragments: [PromptOn.ProjectScoped]

  postgres do
    table "environments"
  end

  actions do
    defaults [:read]

    create :add do
      accept [:slug, :name, :protected?, :position]
    end

    update :rename do
      accept [:name, :protected?, :position]
    end

    update :archive do
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :active do
      filter expr(is_nil(archived_at))
    end

    action :config_snapshot, :map do
      description """
      Assembles this environment's snapshot v3 (plan.md §6.2) via
      `PromptOn.Deployments.Snapshot.build/2`. Result:
      `%{map, body(canonical JSON), etag("sha256-…"), last_modified}`. Environment visibility is
      enforced by the actor's policies.
      """

      argument :environment_id, :uuid, allow_nil?: false

      run fn input, context ->
        PromptOn.Deployments.Snapshot.build(
          input.arguments.environment_id,
          actor: context.actor,
          tenant: context.tenant
        )
      end
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass [PromptOn.Checks.ApiKeyActor, action_type(:read)] do
      description """
      An ApiKey reads its own project's environments. Since keys are not bound to an environment
      (2026-09-01) there is no environment pinning, only tenant pinning; which environment to read
      is chosen by the request parameter.
      """

      authorize_if expr(project_id == ^actor(:project_id))
    end

    policy [PromptOn.Checks.ApiKeyActor, action_type([:create, :update, :destroy])] do
      forbid_if always()
    end

    policy [PromptOn.Checks.ApiKeyActor, action(:config_snapshot)] do
      authorize_if {PromptOn.Checks.ApiKeyScope, scope: :resolve}
    end

    policy action(:config_snapshot) do
      description "Visibility (own project / member) is enforced by the inner Environment read."
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end

    policy action_type([:create, :update]) do
      authorize_if PromptOn.Checks.ProjectMember
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[a-z0-9][a-z0-9-]{0,30}$/
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :protected?, :boolean, allow_nil?: false, public?: true, default: false
    attribute :position, :integer, allow_nil?: false, public?: true, default: 0
    attribute :archived_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug_per_project, [:project_id, :slug]
  end
end
