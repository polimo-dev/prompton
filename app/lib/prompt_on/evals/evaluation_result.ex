defmodule PromptOn.Evals.EvaluationResult do
  @moduledoc """
  One scored log of an `EvaluationRun` — one Oban job each (ADR 0010 §2.6, §3.1).

  **Narrow on purpose.** Unlike `CalibrationSample` it does *not* freeze the payload text: a run is
  a measurement over logs taken minutes ago, not durable reference material, and a 1,000-row text
  snapshot per run would dominate the database for no gain. The worker reads the payload at scoring
  time; a payload that is already gone is a terminal `:failed` with `"payload no longer stored"`.

  `status` is four flat values, not a state machine — there is no lifecycle to guard, and the
  transitions are all "pending -> terminal".

  ## Idempotency (three layers)

  1. AshOban's generated worker is `unique: [keys: [:primary_key, :action_arguments, :tenant],
     period: :infinity, states: :incomplete]`, so while a job for this row is in flight the cron
     scheduler's insert is a no-op.
  2. `worker_read_action :scorable` — a result that is no longer `:pending`, or whose run was
     cancelled, is simply not found and the job is discarded.
  3. `identity :unique_generation_per_run` — the same generation can never be enqueued twice inside
     one run.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Evals,
    fragments: [PromptOn.ProjectScoped],
    extensions: [AshCloak, AshOban]

  alias PromptOn.Evals.EvaluationResult.Changes

  @raw_string [allow_empty?: true, trim?: false]

  @statuses [:pending, :scored, :unparsable, :failed]

  postgres do
    table "evaluation_results"

    references do
      reference :evaluation_run, on_delete: :delete
    end

    custom_indexes do
      index [:project_id, :evaluation_run_id, :status],
        name: "evaluation_results_run_status_index"
    end
  end

  cloak do
    vault(PromptOn.Vault)
    attributes([:rationale])
    decrypt_by_default([])
  end

  oban do
    triggers do
      trigger :score do
        action :score
        where expr(status == :pending and evaluation_run.status in [:queued, :running])
        read_action :scorable
        worker_read_action :scorable

        queue :evals
        scheduler_queue :maintenance
        scheduler_cron "*/2 * * * *"
        record_limit 2_000
        stream_batch_size 200

        max_attempts 3
        backoff :exponential
        on_error :mark_failed
        on_error_fails_job? false

        # An HTTP call must never be made while holding a row lock inside a transaction.
        lock_for_update? false

        worker_module_name PromptOn.Evals.EvaluationResult.Workers.Score
        scheduler_module_name PromptOn.Evals.EvaluationResult.Schedulers.Score
        list_tenants PromptOn.Observability.ProjectTenants
        default_actor(%PromptOn.SystemActor{})
      end
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      description "One pending item of a run. Internal only: `EvaluationRun.:start` writes these."
      accept [:evaluation_run_id, :generation_id, :position]
    end

    update :score do
      description """
      The AshOban worker action: reads the log's payload, asks the judge, and writes the outcome.
      `transaction? false` because an HTTP call must never run inside a database transaction.
      """

      require_atomic? false
      transaction? false

      change Changes.RunJudge
      change Changes.TallyRun
    end

    update :mark_failed do
      description """
      The trigger's `on_error` after the last attempt, and the stall sweeper.

      `tally?: false` suppresses the per-row re-tally. The sweeper failing a stalled 1,000-item run
      would otherwise fire a thousand full re-tallies of a run it has already transitioned to
      `:failed`; it passes `false` and tallies once at the end.
      """

      require_atomic? false
      argument :error, :term
      argument :tally?, :boolean, default: true

      change Changes.MarkFailed
      change Changes.TallyRun
    end

    read :scorable do
      description """
      Items a worker may still score. Used as both `read_action` and `worker_read_action`, so a
      cancelled run's outstanding jobs find nothing and are discarded.
      """

      filter expr(status == :pending and evaluation_run.status in [:queued, :running])
      pagination keyset?: true, required?: false, default_limit: 200, max_page_size: 1_000
    end

    read :for_run do
      argument :evaluation_run_id, :uuid, allow_nil?: false
      argument :status, :atom, constraints: [one_of: @statuses]

      filter expr(
               evaluation_run_id == ^arg(:evaluation_run_id) and
                 (is_nil(^arg(:status)) or status == ^arg(:status))
             )

      prepare build(sort: [position: :asc])
      pagination keyset?: true, default_limit: 50, max_page_size: 200
    end

    read :worst_for_run do
      description "The failures are the product: the 20 lowest-scoring items of a run."
      argument :evaluation_run_id, :uuid, allow_nil?: false

      filter expr(
               evaluation_run_id == ^arg(:evaluation_run_id) and status == :scored and score <= 2
             )

      prepare build(sort: [score: :asc, position: :asc], limit: 20)
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy PromptOn.Checks.ApiKeyActor do
      description "Evals are console-only; the SDK contract has no evals. Read and write are closed."
      forbid_if always()
    end

    policy action([:enqueue, :score, :mark_failed]) do
      description "Written by the run and its judge worker only — the SystemActor bypass is the way in."
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if PromptOn.Checks.ProjectMember
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :generation_id, :uuid do
      description "Soft ref to the scored log (no FK: retention deletes logs, results stay)."
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: @statuses
    end

    attribute :score, :integer, public?: true, constraints: [min: 1, max: 5]

    attribute :rationale, :string do
      description "Why the judge chose that level — encrypted, it quotes the payload."
      public? true
      constraints @raw_string
    end

    attribute :judge_model, :string, public?: true, constraints: @raw_string

    attribute :error_message, :string do
      description "At most 500 characters. Never carries payload text."
      public? true
    end

    attribute :latency_ms, :integer, public?: true, constraints: [min: 0]
    attribute :input_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :output_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :cost_usd, :decimal, public?: true
    attribute :scored_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :evaluation_run, PromptOn.Evals.EvaluationRun do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_generation_per_run, [:evaluation_run_id, :generation_id]
  end

  @doc "Allowed `status` values."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
