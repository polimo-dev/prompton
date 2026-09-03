defmodule PromptOn.Observability.Generation do
  @moduledoc """
  The log of one LLM (provider HTTP) call -- **a narrow, append-only table** (plan.md §5.7). The raw
  content (messages/output/variables) lives in the 1:1 side table `GenerationPayload`; this table
  holds only the columns that serve as dashboard, filter, and aggregation axes.

  - The PK `id` is a **UUIDv7 minted by the SDK** = the idempotency key. `:ingest` is `upsert? true`
    + `upsert_fields []` (DO NOTHING), so resends are absorbed. Server-generated paths
    (playground/experiment, P1) use the default.
  - `source` says **which path** produced the row: `:live` (the app called directly and sent it as
    a monitoring log), `:playground` (the arena), `:experiment`/`:judge` (P1). Adding a value is an
    additive change with no migration (`one_of` is an app-level constraint; the column is text).
    `:proxy` disappeared on 2026-09-01 -- proxy mode (`POST /api/v1/generate`) itself was deleted
    (ADR 0007).
  - `environment_id` is **forced across the batch** by the ingest caller (the environment the
    controller picked from the request parameter) -- a record cannot lie about it.
  - `use_case_key` is stored verbatim and `use_case_id` is filled by ingest resolving the key (nil
    for an unregistered key).
  - `deployment_id/deployment_revision/prompt_version_id/model_id` are **soft refs with no DB FK**
    (`reference ..., ignore?: true`) -- no FK validation on a high-volume append table. The
    resolution basis follows the ADR 0007 vocabulary: "which rule of which Deployment revision
    picked which target" (v1's variant/release/option are gone).
  - `stop_kind` is normalized from `finish_reason` (`PromptOnSDK.StopKind`); cost is estimated from
    the catalog unit price when the provider value is missing (`cost_source :catalog`), and
    `:unknown` when that is missing too.
  - `truncated?` = `stop_kind == :length` (**`tool_call` is not truncation**) -- the truncation
    rate, evaluators, and alerts share this definition.
  - `metadata` carries `model_used`/`upstream_provider`/`http_status` (§6.4; not columns).
  - No destroy (the retention job deletes only payloads). Policy: an ApiKey with the `:logs` scope
    may only run the `:ingest` action; members may only read.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Observability,
    fragments: [PromptOn.ProjectScoped]

  alias PromptOn.Observability.Generation.Changes

  @raw_string [allow_empty?: true, trim?: false]

  @providers [:openrouter, :groq, :openai, :anthropic, :google, :other]
  @sources [:live, :playground, :experiment, :judge]
  @kinds [:chat, :text, :embedding]
  @stop_kinds [:stop, :length, :tool_call, :content_filter, :other]
  @error_kinds [:http_4xx, :http_5xx, :rate_limited, :timeout, :transport, :parse, :app]
  @cost_sources [:provider, :catalog, :unknown]
  @resolution_sources [:remote, :disk, :bundle, :manual]
  @payload_states [:stored, :hashed, :dropped, :truncated]

  postgres do
    table "generations"

    references do
      reference :environment, ignore?: true
      reference :use_case, ignore?: true
      reference :deployment, ignore?: true
      reference :prompt_version, ignore?: true
      reference :catalog_model, ignore?: true
    end

    custom_indexes do
      index [:project_id, {:desc, :started_at}, {:desc, :id}],
        name: "generations_project_started_index"

      index [:project_id, :use_case_id, {:desc, :started_at}],
        name: "generations_project_use_case_started_index"

      index [:project_id, :trace_id], name: "generations_project_trace_index"

      index [:project_id, :end_user_ref, {:desc, :started_at}],
        name: "generations_project_end_user_started_index",
        where: "end_user_ref IS NOT NULL"

      index [:received_at],
        name: "generations_received_at_brin",
        using: "BRIN",
        all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    create :ingest do
      description """
      One record of an SDK batch ingest. A PK conflict is DO NOTHING (idempotent). Validation and
      payload-policy application happen up front in `PromptOn.Observability.Ingest`; this action
      only normalizes (environment forcing, stop_kind, cost correction, error_message truncation)
      -- it has to run cheaply on the bulk_create path.
      """

      upsert? true
      upsert_fields []

      accept [
        :id,
        :environment_id,
        :use_case_id,
        :use_case_key,
        :deployment_id,
        :deployment_revision,
        :prompt,
        :prompt_version_id,
        :model_id,
        :model,
        :provider,
        :source,
        :kind,
        :status,
        :finish_reason,
        :stop_kind,
        :error_kind,
        :error_message,
        :latency_ms,
        :input_tokens,
        :output_tokens,
        :cost_usd,
        :cost_source,
        :trace_id,
        :sequence,
        :end_user_ref,
        :resolution_source,
        :payload_state,
        :sdk_version,
        :started_at,
        :received_at,
        :params,
        :context,
        :metadata
      ]

      change Changes.SetSourceFromActor
      change Changes.NormalizeStopKind
      change Changes.TruncateErrorMessage
      change Changes.EstimateCost
    end

    create :record_playground do
      description """
      One call the Playground screen ran directly (`source :playground`, `environment_id nil`).
      Unlike SDK ingest this is a **row the server creates on its own**, so only the `SystemActor`
      may use it (the policy rejects every other actor). It accepts `id` because the caller has
      already made the raw-content storage decision (`PayloadPolicy.decide/3`) under the same id.
      """

      accept [
        :id,
        :use_case_id,
        :use_case_key,
        :deployment_id,
        :deployment_revision,
        :prompt,
        :prompt_version_id,
        :model_id,
        :model,
        :provider,
        :kind,
        :status,
        :finish_reason,
        :stop_kind,
        :error_kind,
        :error_message,
        :latency_ms,
        :input_tokens,
        :output_tokens,
        :cost_usd,
        :cost_source,
        :payload_state,
        :started_at,
        :received_at,
        :params,
        :metadata
      ]

      change set_attribute(:source, :playground)
      change Changes.NormalizeStopKind
      change Changes.TruncateErrorMessage
      change Changes.EstimateCost
    end

    read :list_for_project do
      description "Log explorer. Keyset paging, started_at desc / id desc. All filters optional."

      argument :use_case_key, :string
      argument :deployment_id, :uuid
      argument :environment_id, :uuid
      argument :status, :atom, constraints: [one_of: [:ok, :error]]
      argument :stop_kind, :atom, constraints: [one_of: @stop_kinds]
      argument :end_user_ref, :string
      argument :trace_id, :string
      argument :from, :utc_datetime_usec
      argument :to, :utc_datetime_usec

      pagination keyset?: true, default_limit: 50, max_page_size: 200

      prepare build(sort: [started_at: :desc, id: :desc])

      filter expr(
               (is_nil(^arg(:use_case_key)) or use_case_key == ^arg(:use_case_key)) and
                 (is_nil(^arg(:deployment_id)) or deployment_id == ^arg(:deployment_id)) and
                 (is_nil(^arg(:environment_id)) or environment_id == ^arg(:environment_id)) and
                 (is_nil(^arg(:status)) or status == ^arg(:status)) and
                 (is_nil(^arg(:stop_kind)) or stop_kind == ^arg(:stop_kind)) and
                 (is_nil(^arg(:end_user_ref)) or end_user_ref == ^arg(:end_user_ref)) and
                 (is_nil(^arg(:trace_id)) or trace_id == ^arg(:trace_id)) and
                 (is_nil(^arg(:from)) or started_at >= ^arg(:from)) and
                 (is_nil(^arg(:to)) or started_at < ^arg(:to))
             )
    end

    read :for_trace do
      description "Rounds of the same trace (truncation retries, tool loops), sequence ascending."
      argument :trace_id, :string, allow_nil?: false
      filter expr(trace_id == ^arg(:trace_id))
      prepare build(sort: [sequence: :asc, started_at: :asc, id: :asc])
    end

    read :for_end_user do
      description "Call history of one end user, newest first."
      argument :end_user_ref, :string, allow_nil?: false
      pagination keyset?: true, default_limit: 50, max_page_size: 200
      filter expr(end_user_ref == ^arg(:end_user_ref))
      prepare build(sort: [started_at: :desc, id: :desc])
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy [PromptOn.Checks.ApiKeyActor, action(:ingest)] do
      description """
      An ApiKey may run only the `:ingest` action, only when it has the `:logs` scope (formerly
      `:ingest`), and **only in its own project** (multitenancy does not stop a tenant that differs
      from the key's project, so it is pinned here -- contract decision #10). The environment is
      forced by a change.
      """

      forbid_unless {PromptOn.Checks.ApiKeyScope, scope: :logs}
      authorize_if expr(project_id == ^actor(:project_id))
    end

    policy [PromptOn.Checks.ApiKeyActor, action_type([:read, :update, :destroy])] do
      description "An ApiKey cannot read logs."
      forbid_if always()
    end

    policy action(:record_playground) do
      description "Server-internal (arena) only -- only the SystemActor bypass above passes it."
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end

    # A member's (User) create/update/destroy has no matching authorize policy, so it is denied by
    # default -- logs are written only by the SDK (ApiKey `:ingest`) and server internals
    # (SystemActor).
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :use_case_key, :string do
      description "The use case key as sent by the SDK. Unregistered keys are stored too."
      allow_nil? false
      public? true
      constraints @raw_string
    end

    attribute :deployment_revision, :integer do
      description "Revision of the resolving Deployment (display only; arrives with the id)."
      public? true
    end

    attribute :prompt, :string do
      description """
      Prompt name chosen at resolution ("default", "ko", ...). The only selection axis now that
      deployments are pins.
      """

      public? true
      constraints @raw_string
    end

    attribute :model, :string do
      description "The model string used in the request, verbatim (`anthropic/claude-sonnet-4`)."
      allow_nil? false
      public? true
      constraints @raw_string
    end

    attribute :provider, :atom do
      allow_nil? false
      public? true
      default :other
      constraints one_of: @providers
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :live
      constraints one_of: @sources
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :chat
      constraints one_of: @kinds
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ok, :error]
    end

    attribute :finish_reason, :string, public?: true, constraints: @raw_string

    attribute :stop_kind, :atom do
      public? true
      constraints one_of: @stop_kinds
    end

    attribute :error_kind, :atom do
      public? true
      constraints one_of: @error_kinds
    end

    attribute :error_message, :string do
      description "≤2KB (ingest truncates the excess)."
      public? true
      constraints @raw_string
    end

    attribute :latency_ms, :integer, public?: true, constraints: [min: 0]
    attribute :input_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :output_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :cost_usd, :decimal, public?: true

    attribute :cost_source, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: @cost_sources
    end

    attribute :trace_id, :string, public?: true, constraints: @raw_string
    attribute :sequence, :integer, public?: true
    attribute :end_user_ref, :string, public?: true, constraints: @raw_string

    attribute :resolution_source, :atom do
      public? true
      constraints one_of: @resolution_sources
    end

    attribute :payload_state, :atom do
      allow_nil? false
      public? true
      default :dropped
      constraints one_of: @payload_states
    end

    attribute :sdk_version, :string, public?: true

    attribute :started_at, :utc_datetime_usec do
      description "Client-side time (start of the call)."
      allow_nil? false
      public? true
    end

    attribute :received_at, :utc_datetime_usec do
      description "Server receive time."
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end

    attribute :params, :map, allow_nil?: false, public?: true, default: %{}

    attribute :context, :map do
      description """
      **Free-form log tags** left by the app (≤2KB). Resolution never looks at the context -- once
      context-dimension routing was deleted (ADR 0007 revision 2026-09-01) this field became pure
      pass-through.
      """

      allow_nil? false
      public? true
      default %{}
    end

    attribute :metadata, :map do
      description """
      Free-form app keys (≤4KB) + model_used/upstream_provider/http_status moved in by ingest.
      """

      allow_nil? false
      public? true
      default %{}
    end
  end

  relationships do
    belongs_to :environment, PromptOn.Projects.Environment do
      public? true
    end

    belongs_to :use_case, PromptOn.Prompts.UseCase do
      public? true
    end

    belongs_to :deployment, PromptOn.Deployments.Deployment do
      description "Soft ref to the resolving Deployment revision (no FK)."
      public? true
    end

    belongs_to :prompt_version, PromptOn.Prompts.PromptVersion do
      public? true
    end

    belongs_to :catalog_model, PromptOn.Catalog.Model do
      description "Catalog model soft ref (`model_id`). `model` is the raw request string."
      source_attribute :model_id
      public? true
    end

    has_one :payload, PromptOn.Observability.GenerationPayload do
      destination_attribute :generation_id
      public? true
    end
  end

  calculations do
    calculate :truncated?, :boolean, expr(not is_nil(stop_kind) and stop_kind == :length) do
      description "Truncated = stop_kind == :length (tool_call is not truncation)."
    end

    calculate :total_tokens, :integer, expr((input_tokens || 0) + (output_tokens || 0))
  end

  @doc "The provider enum (unknown values become `:other`)."
  def providers, do: @providers
  def stop_kinds, do: @stop_kinds
  def error_kinds, do: @error_kinds
  def kinds, do: @kinds
  def sources, do: @sources
  def cost_sources, do: @cost_sources
  def resolution_sources, do: @resolution_sources
end
