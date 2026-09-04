defmodule PromptOn.Evals do
  @moduledoc """
  Manual evaluation of a use case (ADR 0010): sample ten real monitoring logs, let a human score
  them, have the AI write the rubric that explains those scores, check how well the two agree, and
  then score a whole deployment revision with it.

  Six resources, all inside the tenant (`project_id`):

  - `CalibrationSet` / `CalibrationSample` — the ten sampled logs, frozen and encrypted, plus the
    human's 1-5 scores. The set deliberately outlives the logs it came from.
  - `Rubric` (+ the embedded `RubricCriteria`) — immutable and numbered per use case, exactly like
    a `PromptVersion`. "Revise" is a new row.
  - `CalibrationScore` — the AI's score of one sample under one rubric; the agreement evidence.
  - `EvaluationRun` / `EvaluationResult` — the batch: up to 1,000 recent logs of one deployment
    revision x environment, one Oban job per item.

  Three service modules sit beside them: `PromptOn.Evals.Judge` (the only place that builds a
  prompt or calls a model), `PromptOn.Evals.Calibration` (draft / revise / re-score) and
  `PromptOn.Evals.Sampler` + `PromptOn.Evals.PayloadText` (which logs are eligible, and how their
  payload becomes prompt text).

  Evals are **console-only**: an `ApiKey` actor is forbidden on every resource here, and there is
  no public or management API surface for them.
  """

  use Ash.Domain,
    otp_app: :prompton,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource PromptOn.Evals.CalibrationSet do
      define :sample_calibration_set, action: :sample
      define :get_calibration_set, action: :read, get_by: [:id], not_found_error?: false
      define :list_calibration_sets, action: :for_use_case, args: [:use_case_id]

      define :latest_calibration_set,
        action: :latest_for_use_case,
        args: [:use_case_id],
        not_found_error?: false

      define :archive_calibration_set, action: :archive
    end

    resource PromptOn.Evals.CalibrationSample do
      define :capture_calibration_sample, action: :capture
      define :score_calibration_sample, action: :score
      define :list_calibration_samples, action: :for_set, args: [:calibration_set_id]
    end

    resource PromptOn.Evals.Rubric do
      define :draft_rubric, action: :draft
      define :revise_rubric, action: :revise, args: [:source_rubric_id]
      define :write_rubric, action: :write
      define :get_rubric, action: :read, get_by: [:id], not_found_error?: false
      define :list_rubrics, action: :for_use_case, args: [:use_case_id]
      define :current_rubric, action: :current, args: [:use_case_id], not_found_error?: false
    end

    resource PromptOn.Evals.CalibrationScore do
      define :record_calibration_score, action: :record
      define :list_calibration_scores, action: :for_rubric, args: [:rubric_id]
    end

    resource PromptOn.Evals.EvaluationRun do
      define :start_evaluation, action: :start
      define :get_evaluation_run, action: :read, get_by: [:id], not_found_error?: false
      define :list_evaluation_runs, action: :for_use_case, args: [:use_case_id]
      define :active_evaluation_runs, action: :active
      define :cancel_evaluation, action: :cancel
      define :tally_evaluation, action: :tally, args: [:evaluation_run_id]
      define :sweep_stalled_evaluations, action: :sweep_stalled

      define :latest_evaluations_for_deployments,
        action: :latest_for_deployments,
        args: [:deployment_ids]
    end

    resource PromptOn.Evals.EvaluationResult do
      define :list_evaluation_results, action: :for_run, args: [:evaluation_run_id]
      define :worst_evaluation_results, action: :worst_for_run, args: [:evaluation_run_id]
    end
  end

  @doc """
  `deployment_id => the newest completed EvaluationRun`, for the score badges (ADR 0010 §2.7).

  One query for a whole list of revisions. The badge is optional decoration, so a screen that
  cannot load it renders without it rather than failing.
  """
  @spec scores_for_deployments([Ash.UUID.t()], keyword()) :: %{
          Ash.UUID.t() => PromptOn.Evals.EvaluationRun.t()
        }
  def scores_for_deployments([], _opts), do: %{}

  def scores_for_deployments(deployment_ids, opts) do
    case latest_evaluations_for_deployments(deployment_ids, opts) do
      {:ok, runs} -> Map.new(runs, &{&1.deployment_id, &1})
      {:error, _error} -> %{}
    end
  end
end
