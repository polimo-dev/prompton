defmodule PromptOn.Accounts.Invitation do
  @moduledoc """
  Pending invitation into a team organization.

  The invitation is not a membership. It stores the invited address, the role to grant and the
  selected project ids, but no permission takes effect until the invited user opens the emailed
  link and explicitly accepts it. The raw token leaves only in result metadata and email; the
  database stores `token_hash`.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias PromptOn.Accounts.Invitation.{Actions, Changes, Preparations, Validations}

  @ttl_seconds 7 * 24 * 60 * 60

  postgres do
    table "invitations"
    repo PromptOn.Repo

    references do
      reference :organization, on_delete: :delete
      reference :inviter, on_delete: :nilify
      reference :accepted_by, on_delete: :nilify
    end

    custom_indexes do
      index [:organization_id, :email]
      index [:expires_at]
    end
  end

  actions do
    defaults [:read]

    read :list do
      prepare build(sort: [inserted_at: :desc])
      prepare Preparations.FilterList
    end

    create :invite do
      description """
      Creates a pending invitation and sends the invited address an email with a one-use link.
      The actor's invite permissions are checked here, then checked again when the invitation is
      accepted so a later demotion cannot grant stale permissions.
      """

      accept [:organization_id, :email, :role, :project_ids]
      validate Validations.Invitable
      change Changes.SetInviter
      change Changes.GenerateToken
      change Changes.DeliverEmail
    end

    update :revoke do
      description "Revokes a pending invitation before it is accepted."

      require_atomic? false
      change Changes.Revoke
    end

    update :mark_accepted do
      description "Internal accept stamp; `Actions.Accept` owns the transaction and row locks."

      require_atomic? false
      accept [:accepted_at, :accepted_by_id]
    end

    action :preview, :struct do
      description "Token lookup for the Join screen. The signed-in user's email must match."
      constraints instance_of: __MODULE__
      argument :token, :string, allow_nil?: false, sensitive?: true

      run Actions.Preview
    end

    action :accept, :struct do
      description """
      Accepts the invitation once, under a row lock, and creates the membership only after the
      invited user explicitly clicks Join.
      """

      constraints instance_of: __MODULE__
      argument :token, :string, allow_nil?: false, sensitive?: true

      run Actions.Accept
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass action([:preview, :accept]) do
      authorize_if actor_present()
    end

    policy action(:invite) do
      forbid_if PromptOn.Checks.ApiKeyActor
      authorize_if actor_present()
    end

    policy action(:revoke) do
      forbid_if PromptOn.Checks.ApiKeyActor
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if {PromptOn.Checks.OrganizationMember, path: [:organization]}
    end

    policy action(:mark_accepted) do
      forbid_if always()
    end

    policy action_type(:destroy) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :email, :ci_string do
      description "The invited address. Comparisons are case-insensitive."
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      default :member
      constraints one_of: [:member, :admin]
    end

    attribute :project_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
    end

    attribute :token_hash, :string do
      description "sha256 of the raw invitation token. The raw token is never stored."
      allow_nil? false
      sensitive? true
    end

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :accepted_at, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, PromptOn.Accounts.Organization do
      allow_nil? false
      public? true
    end

    belongs_to :inviter, PromptOn.Accounts.User do
      allow_nil? true
      public? true
    end

    belongs_to :accepted_by, PromptOn.Accounts.User do
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_token_hash, [:token_hash]
  end

  @doc "Invitation lifetime in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc "Creates a URL-safe high-entropy token."
  @spec generate_token() :: String.t()
  def generate_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "The only stored form of the token."
  @spec hash(String.t()) :: String.t()
  def hash(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  @doc "Whether the invitation can still be accepted."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{} = invitation) do
    is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at) and
      DateTime.compare(DateTime.utc_now(), invitation.expires_at) == :lt
  end
end
