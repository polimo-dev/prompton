defmodule PromptOn.Observability.GenerationPayload do
  @moduledoc """
  The heavy raw content, 1:1 with a Generation (plan.md §5.7, §9.3). Holds the rendered `input`
  (messages/text), `output` (content/tool_calls), `variables` (variable values before rendering),
  and `usage_raw`, with retention, encryption, and deletion policies different from the narrow
  table.

  - PK = `generation_id` (Generation FK, `on_delete: :delete`).
  - **Encryption**: `AshCloak` encrypts `input/output/variables` with `PromptOn.Vault` (AES-256-GCM,
    `PTN_VAULT_KEY`) into `encrypted_input/encrypted_output/encrypted_variables` (bytea,
    `term_to_binary` → ciphertext → base64) and decrypts them through **calculations** of the same
    name -- they are not loaded by default (`decrypt_by_default []`), so the raw content is only
    decrypted where `load: [:input, :output, :variables]` is explicit (the detail screen). P0
    always encrypts regardless of the policy's `encrypt?` (`encrypted?` records what was stored).
  - Sizes and hashes: `bytes_in/bytes_out` are the size of the raw JSON the SDK sent,
    `input_sha256/output_sha256` the sha256 of that JSON -- in `mode :hash` only these four remain
    ("same input recurring" detection). `truncated?` is whether the SDK or the server truncated.
  - `expires_at` = `received_at + retention_days` (`:store` argument) -- retention deletion becomes
    a simple range query.
  - Actions: `:store` (ingest-internal, DO NOTHING upsert), `:purge_expired` (generic -- reads
    `:expired` 5,000 rows at a time and runs `bulk_destroy(:destroy, strategy: [:atomic])`),
    `:purge_for_end_user` (generic). The plain `:destroy` exists only for those two and is not
    exposed in the code_interface.
  - Policy: members read only. Writes and deletes are SystemActor only (the ingest service, the
    retention job, mix tasks).
  - Retention job: AshOban `scheduled_actions` daily at 03:10 UTC on the `maintenance` queue, one
    job per project (tenant).
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Observability,
    fragments: [PromptOn.ProjectScoped],
    extensions: [AshCloak, AshOban]

  alias PromptOn.Observability.GenerationPayload.{Actions, Changes}

  postgres do
    table "generation_payloads"

    references do
      reference :generation, on_delete: :delete
    end

    custom_indexes do
      index [:expires_at], name: "generation_payloads_expires_at_brin", using: "BRIN"
    end
  end

  cloak do
    vault(PromptOn.Vault)
    attributes([:input, :output, :variables])
    decrypt_by_default([])
  end

  oban do
    scheduled_actions do
      schedule :purge_expired_payloads, "10 3 * * *" do
        action :purge_expired
        queue :maintenance
        worker_module_name PromptOn.Observability.GenerationPayload.Workers.PurgeExpired
        list_tenants PromptOn.Observability.ProjectTenants
        default_actor(%PromptOn.SystemActor{})
        max_attempts 1
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :store do
      description "Ingest-internal only. Resending the same generation_id is DO NOTHING."

      upsert? true
      upsert_fields []

      argument :retention_days, :integer do
        description "PayloadPolicy.retention_days -- expires_at = received_at + retention_days."
        allow_nil? false
        default 30
        constraints min: 1, max: 365
      end

      accept [
        :generation_id,
        :input,
        :output,
        :variables,
        :usage_raw,
        :input_sha256,
        :output_sha256,
        :bytes_in,
        :bytes_out,
        :truncated?,
        :encrypted?,
        :received_at
      ]

      change Changes.SetExpiresAt
    end

    read :expired do
      description "Raw content past its retention period."
      filter expr(expires_at < now())
    end

    action :purge_expired, :map do
      description """
      Deletes expired raw content (the retention job). Deletes `expires_at < now()` rows
      `batch_size` at a time, at most `max_batches` times. Without a tenant it walks every
      project. Returns `%{deleted: n}`.
      """

      argument :batch_size, :integer, default: 5_000, constraints: [min: 1, max: 50_000]
      argument :max_batches, :integer, default: 200, constraints: [min: 1]
      argument :last_oban_attempt?, :boolean, default: false

      run Actions.PurgeExpired
    end

    action :purge_for_end_user, :map do
      description """
      Deletes all raw content of one end user (`end_user_ref`) -- the HeyDiary account-deletion
      hook. Returns `%{deleted: n}`.
      """

      argument :end_user_ref, :string, allow_nil?: false
      run Actions.PurgeForEndUser
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy PromptOn.Checks.ApiKeyActor do
      description """
      An ApiKey can neither read nor write raw content (the ingest service stores it as the
      SystemActor).
      """

      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end

    # create/destroy/generic are SystemActor only (bypass). Members have no matching policy, so
    # they are denied by default.
  end

  attributes do
    attribute :generation_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :input, :map do
      description "Rendered messages (chat) or text -- encrypted."
      public? true
    end

    attribute :output, :map do
      description "content / tool_calls -- encrypted."
      public? true
    end

    attribute :variables, :map do
      description "Pre-render variable values (for replay and dataset promotion) -- encrypted."
      public? true
    end

    attribute :usage_raw, :map, public?: true

    attribute :input_sha256, :string, public?: true
    attribute :output_sha256, :string, public?: true
    attribute :bytes_in, :integer, public?: true, constraints: [min: 0]
    attribute :bytes_out, :integer, public?: true, constraints: [min: 0]

    attribute :truncated?, :boolean do
      source :truncated
      allow_nil? false
      public? true
      default false
    end

    attribute :encrypted?, :boolean do
      source :encrypted
      allow_nil? false
      public? true
      default true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :received_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end
  end

  relationships do
    belongs_to :generation, PromptOn.Observability.Generation do
      define_attribute? false
      allow_nil? false
      public? true
    end
  end
end
