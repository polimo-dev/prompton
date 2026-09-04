defmodule PromptOn.Evals.CalibrationSample do
  @moduledoc """
  One sampled monitoring log, **frozen**, plus the human's 1-5 score (ADR 0010 §2.2).

  - `generation_id` is a **soft reference with no FK**. The source `Generation` will eventually be
    deleted by the retention purge; the evidence the rubric was written from must not evaporate
    with it. That is also why `input_text`/`output_text` are copies rather than a join.
  - Both texts are encrypted with `PromptOn.Vault` and **not** decrypted by default: the list view
    of a set never needs them, and loading them there would drag every row through AES. The scoring
    screen and the judge ask for them explicitly with `load: [:input_text, :output_text]`. This is
    exactly the `GenerationPayload` contract.
  - `:capture` is internal (the sampler runs it as the system actor); the only action a member
    calls is `:score`.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Evals,
    fragments: [PromptOn.ProjectScoped],
    extensions: [AshCloak]

  @raw_string [allow_empty?: true, trim?: false]

  postgres do
    table "calibration_samples"

    references do
      reference :calibration_set, on_delete: :delete
    end

    custom_indexes do
      index [:project_id, :calibration_set_id, :position],
        name: "calibration_samples_set_position_index"
    end
  end

  cloak do
    vault(PromptOn.Vault)
    attributes([:input_text, :output_text])
    decrypt_by_default([])
  end

  actions do
    defaults [:read]

    create :capture do
      description """
      Freezes one sampled log into the set. Internal only: `CalibrationSet.:sample` runs it as the
      system actor, and the policy forbids every other actor.
      """

      accept [
        :calibration_set_id,
        :generation_id,
        :position,
        :input_text,
        :output_text,
        :truncated?,
        :model,
        :deployment_revision,
        :started_at
      ]
    end

    update :score do
      description "The human's 1-5 score for this sample, written the moment a star is clicked."

      require_atomic? false
      accept [:user_score, :user_note]

      validate present(:user_score)

      change set_attribute(:scored_at, &DateTime.utc_now/0)
      change {PromptOn.Evals.Changes.SetActorId, attribute: :scored_by}
    end

    read :for_set do
      description "The samples of one set, in display order."
      argument :calibration_set_id, :uuid, allow_nil?: false
      filter expr(calibration_set_id == ^arg(:calibration_set_id))
      prepare build(sort: [position: :asc])
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

    policy action(:capture) do
      description "Written by the sampler only — the SystemActor bypass above is the only way in."
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
      description "Soft ref to the source log (no FK: the log is purged, the sample survives)."
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      description "1..N, the stable display order inside the set."
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :input_text, :string do
      description "Frozen, truncated input of the source log — encrypted."
      public? true
      constraints @raw_string
    end

    attribute :output_text, :string do
      description "Frozen, truncated output of the source log — encrypted."
      public? true
      constraints @raw_string
    end

    attribute :truncated?, :boolean do
      description "Either side was cut by `PromptOn.Evals.PayloadText`."
      source :truncated
      allow_nil? false
      public? true
      default false
    end

    attribute :model, :string, public?: true, constraints: @raw_string
    attribute :deployment_revision, :integer, public?: true
    attribute :started_at, :utc_datetime_usec, public?: true

    attribute :user_score, :integer do
      description "The human's score, nil until they give one."
      public? true
      constraints min: 1, max: 5
    end

    attribute :user_note, :string, public?: true

    attribute :scored_by, :uuid do
      description "Soft ref to the scoring User (User is outside the tenant, so no FK)."
      public? true
    end

    attribute :scored_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :calibration_set, PromptOn.Evals.CalibrationSet do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :scored?, :boolean, expr(not is_nil(user_score))
  end

  identities do
    identity :unique_generation_per_set, [:calibration_set_id, :generation_id]
  end
end
