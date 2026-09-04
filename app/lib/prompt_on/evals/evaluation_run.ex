defmodule PromptOn.Evals.EvaluationRun do
  @moduledoc """
  One batch evaluation of a deployment revision against a rubric (ADR 0010 §2.6).

  This is the **only** resource in the evals area with a state machine, per the CLAUDE.md rule
  ("only resources that need a state machine get `AshStateMachine`"). It genuinely needs one: a
  batch of up to 1,000 background jobs has a lifecycle that outlives any single request, and two
  concurrent tallies both trying to complete the run must not both win.

  The result columns (`average_score`, `score_distribution`, the counts, `cost_usd`) are **frozen**
  by the `:tally` action from the `results_*` aggregates. They are a measurement, not a live view:
  the numbers a run reports must not change when a result row is deleted later.

  ## Why the score is not a column on `Deployment` (ADR 0010 §2.7)

  A revision is measured many times — rubric v1 says 3.4, the tightened v2 says 2.9, a fresh
  thousand logs say 3.1 — and all three are true statements about different measurements. A column
  can hold only the last one and silently loses which rubric and which window produced it.
  `Deployment` is also immutable by contract (it has no update action) and sits on the
  `GET /use-cases` hot path, where an ApiKey reads it. So `PromptOn.Deployments` does not know that
  `PromptOn.Evals` exists; the badge is read through `:latest_for_deployments`, one query per
  screen.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Evals,
    fragments: [PromptOn.ProjectScoped],
    extensions: [AshStateMachine, AshOban]

  alias PromptOn.Evals.EvaluationRun.{Actions, Changes, Validations}

  @raw_string [allow_empty?: true, trim?: false]

  @statuses [:queued, :running, :completed, :failed, :cancelled]

  postgres do
    table "evaluation_runs"

    # `identity :one_active_run_per_deployment` filters in Ash expressions; Postgres needs the same
    # predicate as SQL for the partial unique index.
    identity_wheres_to_sql one_active_run_per_deployment: "status IN ('queued', 'running')"

    references do
      reference :use_case, on_delete: :delete
      reference :deployment, on_delete: :delete
      reference :environment, on_delete: :delete
      reference :rubric, on_delete: :delete
    end

    custom_indexes do
      index [:project_id, :deployment_id, :status],
        name: "evaluation_runs_deployment_status_index"
    end
  end

  state_machine do
    initial_states [:queued]
    default_initial_state :queued
    state_attribute :status

    transitions do
      transition :mark_running, from: :queued, to: :running
      transition :complete, from: [:queued, :running], to: :completed
      transition :fail, from: [:queued, :running], to: :failed
      transition :cancel, from: [:queued, :running], to: :cancelled
    end
  end

  oban do
    scheduled_actions do
      schedule :sweep_stalled_evaluations, "*/10 * * * *" do
        action :sweep_stalled
        queue :maintenance
        worker_module_name PromptOn.Evals.EvaluationRun.Workers.SweepStalled
        list_tenants PromptOn.Observability.ProjectTenants
        default_actor(%PromptOn.SystemActor{})
        max_attempts 1
      end
    end
  end

  actions do
    defaults [:read]

    create :start do
      description """
      The Evaluate button. Validates the target, freezes the judge model, samples the eligible logs
      of that deployment revision x environment, and writes one `EvaluationResult` per sample — all
      in one transaction. The scoring jobs are enqueued after the transaction commits.
      """

      accept [:use_case_id, :deployment_id, :environment_id, :rubric_id, :sample_limit]

      validate Validations.TargetInTenant
      validate Validations.NoActiveRun
      validate Validations.JudgeAvailable

      change {PromptOn.Evals.Changes.SetActorId, attribute: :requested_by}
      change Changes.FreezeJudgeModel
      change Changes.SampleGenerations
      change Changes.EnqueueJobs
    end

    update :record_tally do
      description """
      Freezes the result counters onto the run. Internal only: `:tally` is the only caller, and it
      is the only writer of these columns — they are a measurement, not a live view.
      """

      require_atomic? false

      accept [
        :scored_count,
        :unparsable_count,
        :failed_count,
        :average_score,
        :score_distribution,
        :cost_usd
      ]
    end

    update :mark_running do
      description "First scored result flips the run out of `:queued`."
      require_atomic? false
      change transition_state(:running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :complete do
      require_atomic? false
      change transition_state(:completed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end

    update :fail do
      require_atomic? false
      accept [:error_message]
      change transition_state(:failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end

    update :cancel do
      description """
      Stops a run. Outstanding jobs find nothing (the `:scorable` read excludes a cancelled run's
      results) and are discarded. The pending results are deliberately left as they are, so
      "cancelled at item 342" stays readable.
      """

      require_atomic? false
      change transition_state(:cancelled)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end

    action :tally, :map do
      description """
      Freezes the result counters onto the run and, when nothing is pending any more, completes it
      (or fails it when nothing was scored at all). Internal only. Returns
      `%{status: atom, pending: integer}`.
      """

      argument :evaluation_run_id, :uuid, allow_nil?: false
      run Actions.Tally
    end

    action :sweep_stalled, :map do
      description """
      The safety net (every 10 minutes): finalizes runs whose last tally was lost to a crash, and
      fails runs that have been going for more than two hours. Returns
      `%{finalized: n, failed: n}`.
      """

      argument :stall_after_seconds, :integer, default: 7_200, constraints: [min: 60]
      argument :last_oban_attempt?, :boolean, default: false

      run Actions.SweepStalled
    end

    read :for_use_case do
      argument :use_case_id, :uuid, allow_nil?: false
      filter expr(use_case_id == ^arg(:use_case_id))
      prepare build(sort: [inserted_at: :desc])
      pagination keyset?: true, default_limit: 20, max_page_size: 100
    end

    read :latest_for_deployments do
      description "The newest completed run per deployment revision (the badge source)."
      argument :deployment_ids, {:array, :uuid}, allow_nil?: false

      filter expr(status == :completed and deployment_id in ^arg(:deployment_ids))
      prepare build(distinct: [:deployment_id], distinct_sort: [finished_at: :desc])
    end

    read :active do
      description "Runs that are still queued or running."
      filter expr(status in [:queued, :running])
      prepare build(sort: [inserted_at: :asc])
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

    policy action([:record_tally, :mark_running, :complete, :fail, :tally, :sweep_stalled]) do
      description """
      Lifecycle transitions the server drives itself — only the SystemActor bypass above gets
      through. `:cancel` is deliberately absent: it is the one transition a member may call.
      """

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

    attribute :status, :atom do
      description "State machine: queued -> running -> completed | failed | cancelled."
      allow_nil? false
      public? true
      default :queued
      constraints one_of: @statuses
    end

    attribute :deployment_revision, :integer do
      description "Denormalized for display; a run outlives nothing but it saves a join."
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :rubric_number, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :judge_model, :string do
      description "Frozen at `:start` so a mid-run change of the org default cannot skew the run."
      allow_nil? false
      public? true
      constraints @raw_string
    end

    attribute :sample_limit, :integer do
      description """
      How many logs were asked for. There is no `max` constraint on purpose: the ceiling is
      `PromptOn.Entitlements.limit(plan, :evaluation_sample_limit)`, and
      `Changes.SampleGenerations` clamps to it before this value is written. A hard-coded max here
      would refuse the one change the entitlement exists to make cheap — raising a plan's limit.
      """

      allow_nil? false
      public? true
      default 1_000
      constraints min: 1
    end

    attribute :item_count, :integer do
      description "How many results were actually enqueued."
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :scored_count, :integer, allow_nil?: false, public?: true, default: 0
    attribute :unparsable_count, :integer, allow_nil?: false, public?: true, default: 0
    attribute :failed_count, :integer, allow_nil?: false, public?: true, default: 0

    attribute :average_score, :decimal do
      description "Mean of the `:scored` results only. nil while nothing has been scored."
      public? true
    end

    attribute :score_distribution, :map do
      description ~s|`%{"1" => n, ... "5" => n}` — frozen by `:tally`.|
      allow_nil? false
      public? true
      default %{}
    end

    attribute :cost_usd, :decimal, public?: true

    attribute :window_from, :utc_datetime_usec, public?: true
    attribute :window_to, :utc_datetime_usec, public?: true

    attribute :requested_by, :uuid do
      description "Soft ref to the User who started the run (User is outside the tenant)."
      public? true
    end

    attribute :started_at, :utc_datetime_usec, public?: true
    attribute :finished_at, :utc_datetime_usec, public?: true

    attribute :error_message, :string do
      description "At most 500 characters. Never carries payload text."
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :use_case, PromptOn.Prompts.UseCase do
      allow_nil? false
      public? true
    end

    belongs_to :deployment, PromptOn.Deployments.Deployment do
      description "The revision being measured."
      allow_nil? false
      public? true
    end

    belongs_to :environment, PromptOn.Projects.Environment do
      allow_nil? false
      public? true
    end

    belongs_to :rubric, PromptOn.Evals.Rubric do
      allow_nil? false
      public? true
    end

    has_many :results, PromptOn.Evals.EvaluationResult do
      public? true
    end
  end

  calculations do
    calculate :active?, :boolean, expr(status in [:queued, :running])

    calculate :progress,
              :float,
              expr(
                if item_count > 0 do
                  type(scored_count + unparsable_count + failed_count, :float) /
                    type(item_count, :float)
                else
                  0.0
                end
              )
  end

  aggregates do
    count :results_total, :results

    count :results_pending, :results do
      filter expr(status == :pending)
    end

    count :results_scored, :results do
      filter expr(status == :scored)
    end

    count :results_unparsable, :results do
      filter expr(status == :unparsable)
    end

    count :results_failed, :results do
      filter expr(status == :failed)
    end

    count :results_score_1, :results do
      filter expr(score == 1)
    end

    count :results_score_2, :results do
      filter expr(score == 2)
    end

    count :results_score_3, :results do
      filter expr(score == 3)
    end

    count :results_score_4, :results do
      filter expr(score == 4)
    end

    count :results_score_5, :results do
      filter expr(score == 5)
    end

    avg :results_score_avg, :results, :score do
      filter expr(status == :scored)
    end

    sum :results_cost, :results, :cost_usd
  end

  identities do
    # The **real** guard against two concurrent runs over one revision: `Validations.NoActiveRun`
    # runs while the changeset is built, outside the transaction and without a lock, so two clicks
    # in two tabs both read nil. This partial unique index makes the second insert fail in Postgres.
    identity :one_active_run_per_deployment, [:deployment_id] do
      where expr(status in [:queued, :running])
      message "an evaluation of this revision is already running"
    end
  end

  @doc "Allowed `status` values."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
