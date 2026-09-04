defmodule PromptOn.Evals.CalibrationScore do
  @moduledoc """
  The AI's score of one calibration sample under one rubric version — the agreement evidence
  (ADR 0010 §2.5).

  `absolute_error` and `within_one?` are **denormalized on write** so the agreement aggregates on
  `Rubric` are pure SQL. `rationale` is encrypted (the judge quotes the payload back) and is not
  decrypted by default.

  `:record` is an upsert on `(rubric_id, calibration_sample_id)`, so "re-score with this rubric" is
  idempotent and never duplicates rows.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Evals,
    fragments: [PromptOn.ProjectScoped],
    extensions: [AshCloak]

  @raw_string [allow_empty?: true, trim?: false]

  @statuses [:ok, :unparsable, :failed]

  postgres do
    table "calibration_scores"

    references do
      reference :rubric, on_delete: :delete
      reference :calibration_sample, on_delete: :delete
    end
  end

  cloak do
    vault(PromptOn.Vault)
    attributes([:rationale])
    decrypt_by_default([])
  end

  actions do
    defaults [:read]

    create :record do
      description """
      Writes (or overwrites) the AI's score of one sample under one rubric. Internal only: the
      calibration service runs it as the system actor.
      """

      upsert? true
      upsert_identity :unique_score

      upsert_fields [
        :status,
        :score,
        :encrypted_rationale,
        :absolute_error,
        :within_one?,
        :judge_model,
        :error_message,
        :latency_ms,
        :input_tokens,
        :output_tokens,
        :cost_usd,
        :updated_at
      ]

      accept [
        :rubric_id,
        :calibration_sample_id,
        :status,
        :score,
        :rationale,
        :judge_model,
        :error_message,
        :latency_ms,
        :input_tokens,
        :output_tokens,
        :cost_usd
      ]

      change PromptOn.Evals.CalibrationScore.Changes.ComputeError
    end

    read :for_rubric do
      argument :rubric_id, :uuid, allow_nil?: false
      filter expr(rubric_id == ^arg(:rubric_id))
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

    policy action(:record) do
      description "Written by the judge only — the SystemActor bypass above is the only way in."
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
      allow_nil? false
      public? true
      default :ok
      constraints one_of: @statuses
    end

    attribute :score, :integer do
      description "The AI's 1-5 score. nil unless `status` is `:ok`."
      public? true
      constraints min: 1, max: 5
    end

    attribute :rationale, :string do
      description "Why the judge chose that level — encrypted, it quotes the payload."
      public? true
      constraints @raw_string
    end

    attribute :absolute_error, :integer do
      description "`abs(score - sample.user_score)`. nil unless `status` is `:ok`."
      public? true
      constraints min: 0, max: 4
    end

    attribute :within_one?, :boolean do
      description "`absolute_error <= 1`."
      source :within_one
      allow_nil? false
      public? true
      default false
    end

    attribute :judge_model, :string do
      description "The model that actually produced this score."
      allow_nil? false
      public? true
      constraints @raw_string
    end

    attribute :error_message, :string do
      description "Set for `:unparsable` / `:failed`, at most 500 characters."
      public? true
    end

    attribute :latency_ms, :integer, public?: true, constraints: [min: 0]
    attribute :input_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :output_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :cost_usd, :decimal, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :rubric, PromptOn.Evals.Rubric do
      allow_nil? false
      public? true
    end

    belongs_to :calibration_sample, PromptOn.Evals.CalibrationSample do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_score, [:rubric_id, :calibration_sample_id]
  end

  @doc "Allowed `status` values."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
