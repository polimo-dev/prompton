defmodule PromptOn.Evals.Rubric do
  @moduledoc """
  An evaluation rubric of one use case — **immutable and numbered** (ADR 0010 §2.4).

  The current rubric of a use case is **the highest number**, exactly as the live deployment is the
  highest revision (ADR 0007). There is no status column and no `active?` flag, and there is **no
  update action at all**: "revise" is `:revise`, which is a create.

  Agreement with the human is not stored on the row. It is aggregated over `CalibrationScore`
  (`mean_absolute_error`, `within_one_ratio`, `exact_ratio`, `scored_count`), so it is always
  consistent with the score rows and survives a re-score, which upserts them.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Evals,
    fragments: [PromptOn.ProjectScoped]

  alias PromptOn.Evals.Rubric.{Changes, Validations}

  @raw_string [allow_empty?: true, trim?: false]

  @sources [:ai_draft, :ai_revision, :manual]

  postgres do
    table "rubrics"

    references do
      reference :use_case, on_delete: :delete
      reference :calibration_set, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    create :draft do
      description "The AI's first rubric, written from a scored calibration set."

      accept [:use_case_id, :calibration_set_id, :criteria, :judge_model]

      validate Validations.CalibrationSetInTenant

      change set_attribute(:source, :ai_draft)
      change {PromptOn.Evals.Changes.SetActorId, attribute: :authored_by}
      change Changes.AssignNumber
    end

    create :revise do
      description """
      A new version derived from an existing one. `use_case_id`, `calibration_set_id` and (when the
      caller leaves it nil) `judge_model` are copied from the source, which must be in the same
      tenant and on the same use case.
      """

      accept [:criteria, :judge_model, :note]
      argument :source_rubric_id, :uuid, allow_nil?: false

      change Changes.CopyFromSource
      change set_attribute(:source, :ai_revision)
      change {PromptOn.Evals.Changes.SetActorId, attribute: :authored_by}
      change Changes.AssignNumber
    end

    create :write do
      description """
      The manual editor. With `source_rubric_id` it behaves like `:revise`; without one it is a
      hand-written first rubric and `use_case_id` is given directly.
      """

      accept [:use_case_id, :calibration_set_id, :criteria, :judge_model, :note]
      argument :source_rubric_id, :uuid

      change Changes.CopyFromSource
      validate Validations.CalibrationSetInTenant
      change set_attribute(:source, :manual)
      change {PromptOn.Evals.Changes.SetActorId, attribute: :authored_by}
      change Changes.AssignNumber
    end

    read :for_use_case do
      argument :use_case_id, :uuid, allow_nil?: false
      filter expr(use_case_id == ^arg(:use_case_id))
      prepare build(sort: [number: :desc])
    end

    read :current do
      description "The current rubric of a use case = the highest number; nil when there is none."
      argument :use_case_id, :uuid, allow_nil?: false
      get? true

      filter expr(use_case_id == ^arg(:use_case_id))
      prepare build(sort: [number: :desc], limit: 1)
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

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if PromptOn.Checks.ProjectMember
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :number, :integer do
      description "Monotonically increasing within a use case; the highest is the current rubric."
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :criteria, PromptOn.Evals.RubricCriteria do
      allow_nil? false
      public? true
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: @sources
    end

    attribute :note, :string do
      description "The revision note the human gave. nil for the first rubric."
      public? true
      constraints @raw_string
    end

    attribute :judge_model, :string do
      description """
      Per-rubric judge model override. nil falls back to the organization, then the app default.
      """

      public? true
      constraints @raw_string
    end

    attribute :authored_by, :uuid do
      description "Soft ref to the authoring User (User is outside the tenant, so no FK)."
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :use_case, PromptOn.Prompts.UseCase do
      allow_nil? false
      public? true
    end

    belongs_to :calibration_set, PromptOn.Evals.CalibrationSet do
      description "The set this rubric was drafted from; nil for a hand-written first rubric."
      public? true
    end

    has_many :calibration_scores, PromptOn.Evals.CalibrationScore do
      public? true
    end
  end

  calculations do
    calculate :within_one_ratio,
              :float,
              expr(
                if scored_count > 0 do
                  type(within_one_count, :float) / type(scored_count, :float)
                else
                  nil
                end
              )

    calculate :exact_ratio,
              :float,
              expr(
                if scored_count > 0 do
                  type(exact_count, :float) / type(scored_count, :float)
                else
                  nil
                end
              )
  end

  aggregates do
    count :scored_count, :calibration_scores do
      filter expr(status == :ok)
    end

    count :within_one_count, :calibration_scores do
      filter expr(status == :ok and within_one? == true)
    end

    count :exact_count, :calibration_scores do
      filter expr(status == :ok and absolute_error == 0)
    end

    count :unparsable_count, :calibration_scores do
      filter expr(status != :ok)
    end

    avg :mean_absolute_error, :calibration_scores, :absolute_error do
      filter expr(status == :ok)
    end
  end

  identities do
    identity :unique_number_per_use_case, [:use_case_id, :number]
  end

  @doc "Allowed `source` values."
  @spec sources() :: [atom()]
  def sources, do: @sources
end
