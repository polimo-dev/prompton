defmodule PromptOn.Projects.ApiKey do
  @moduledoc """
  SDK machine key: **owned by a project**, `scopes [:read, :logs]`, only the sha256 hash is
  stored (plan.md §5.4). The raw `ptn_<project_slug>_<random32>` leaves **exactly once**, as the
  `:raw_key` metadata of the `:issue` result.

  Keys are **not bound to an environment** (2026-09-01): the environment is chosen by the request
  parameter (`environment`, default `"production"`). One key can call both production and staging;
  if separation is needed, split the project.

  Resource outside the tenant: the key lookup (`:by_raw_key`) happens before the tenant is known, so
  multitenancy is not enabled and only policies guard it. The record itself becomes the actor of the
  public API (`PromptOnWeb.Plugs.ApiKeyAuth`).
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "api_keys"
    repo PromptOn.Repo

    references do
      reference :project, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :issue do
      description "Issue a key; raw key exposed once via `Ash.Resource.get_metadata(record, :raw_key)`."
      accept [:project_id, :name, :scopes, :expires_at]
      change PromptOn.Projects.ApiKey.Changes.GenerateKey
    end

    update :revoke do
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end

    update :touch_last_used do
      description "Called by the plug only when more than 5 minutes have passed."
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end

    read :by_raw_key do
      description "Raw Bearer value -> sha256 -> one valid (not revoked, not expired) key."
      argument :raw_key, :string, allow_nil?: false, sensitive?: true
      get? true
      prepare PromptOn.Projects.ApiKey.Preparations.FilterByRawKey
    end

    read :for_project do
      argument :project_id, :uuid, allow_nil?: false
      filter expr(project_id == ^arg(:project_id))
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass action(:by_raw_key) do
      description "The auth plug calls this with no actor; the actor is the result of this lookup."
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end

    policy action_type(:create) do
      authorize_if relates_to_actor_via([:project, :organization, :memberships, :user])
    end

    policy action(:touch_last_used) do
      description "Only the key itself (the ApiKey actor) may touch it."
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:revoke) do
      authorize_if PromptOn.Checks.ProjectMember
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true

    # Fixed first 16 characters of the raw key (for display). The `ptn_<project_slug>_` prefix
    # length varies per slug, so it is 16 characters regardless of the slug.
    attribute :key_prefix, :string, allow_nil?: false, public?: true
    attribute :key_hash, :string, allow_nil?: false, sensitive?: true

    attribute :scopes, {:array, :atom} do
      allow_nil? false
      public? true

      # `:read` = config-fetch (`GET /use-cases`, `POST /use-cases/:key/prompt`), `:logs` = monitoring logs
      # (`POST /logs`). `:logs` replaced `:ingest` on 2026-09-01 (agent-first-spec §2).
      default [:read, :logs]
      constraints items: [one_of: [:read, :logs]]
    end

    attribute :last_used_at, :utc_datetime_usec, public?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :project, PromptOn.Projects.Project do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :active?,
              :boolean,
              expr(is_nil(revoked_at) and (is_nil(expires_at) or expires_at > now()))
  end

  identities do
    identity :unique_key_hash, [:key_hash]
  end

  @doc "Stored hash of the raw key (sha256 hex)."
  def hash(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
