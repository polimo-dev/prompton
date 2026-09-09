defmodule PromptOn.Observability.AIUsage do
  @moduledoc """
  One completed Draft or Evaluation provider call, independent of its authoring/scoring result.

  Costs are append-only: regenerating a draft or re-scoring a sample spends again even when the
  editable result is replaced. This table contains no prompts, responses or provider bodies and
  does not consume the monitoring log retention quota. Project deletion removes its usage.

  The initial migration snapshots recoverable evaluation costs. Calibration history contains
  only the last stored attempt; earlier drafts, rubric generation and overwritten scores cannot
  be reconstructed. EvaluationRun totals are never imported because they duplicate results.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Observability,
    fragments: [PromptOn.ProjectScoped]

  postgres do
    table "ai_usages"

    custom_indexes do
      index [:project_id, :started_at], name: "ai_usages_project_started_index"
    end

    custom_statements do
      statement :recover_evaluation_usage do
        after_tables [
          "ai_usages",
          "evaluation_results",
          "evaluation_runs",
          "calibration_scores",
          "rubrics",
          "use_cases"
        ]

        up """
        INSERT INTO ai_usages
          (id, project_id, use_case_key, operation, model, input_tokens, output_tokens,
           cost_usd, started_at, inserted_at)
        SELECT result.id, result.project_id, use_case.key, 'evaluation',
               COALESCE(result.judge_model, run.judge_model), result.input_tokens,
               result.output_tokens, result.cost_usd,
               COALESCE(result.scored_at, result.updated_at), now()
        FROM evaluation_results AS result
        JOIN evaluation_runs AS run
          ON run.id = result.evaluation_run_id AND run.project_id = result.project_id
        JOIN use_cases AS use_case
          ON use_case.id = run.use_case_id AND use_case.project_id = result.project_id
        WHERE result.cost_usd IS NOT NULL OR result.input_tokens IS NOT NULL
           OR result.output_tokens IS NOT NULL
        UNION ALL
        SELECT score.id, score.project_id, use_case.key, 'evaluation', score.judge_model,
               score.input_tokens, score.output_tokens, score.cost_usd, score.updated_at, now()
        FROM calibration_scores AS score
        JOIN rubrics AS rubric
          ON rubric.id = score.rubric_id AND rubric.project_id = score.project_id
        JOIN use_cases AS use_case
          ON use_case.id = rubric.use_case_id AND use_case.project_id = score.project_id
        WHERE score.status = 'ok' AND
          (score.cost_usd IS NOT NULL OR score.input_tokens IS NOT NULL
           OR score.output_tokens IS NOT NULL)
        ON CONFLICT (id) DO NOTHING
        """

        down "SELECT 1"
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "Internal accounting for one completed provider call, before parsing its output."

      accept [
        :use_case_key,
        :operation,
        :model,
        :input_tokens,
        :output_tokens,
        :cost_usd,
        :started_at
      ]
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy PromptOn.Checks.ApiKeyActor do
      forbid_if always()
    end

    policy action(:record) do
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :use_case_key, :string, allow_nil?: false, public?: true

    attribute :operation, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:draft, :evaluation]]

    attribute :model, :string, allow_nil?: false, public?: true
    attribute :input_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :output_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :cost_usd, :decimal, public?: true, constraints: [min: 0]
    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true

    create_timestamp :inserted_at
  end
end
