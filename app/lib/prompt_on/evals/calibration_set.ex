defmodule PromptOn.Evals.CalibrationSet do
  @moduledoc """
  The ten monitoring logs of one use case that a human scores by hand, taken at one moment
  (ADR 0010 §2.1).

  Re-sampling makes a **new** set; the hub shows the latest non-archived one. A set is the evidence
  a rubric was derived from, so it freezes the sampled text into its `CalibrationSample` rows
  (`:sample` is the only creation path).
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Evals,
    fragments: [PromptOn.ProjectScoped]

  postgres do
    table "calibration_sets"

    references do
      reference :use_case, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :sample do
      description """
      Samples `sample_size` eligible monitoring logs of the use case and freezes them as
      `CalibrationSample` rows in the same transaction. Fewer than five eligible logs is refused:
      a half-empty calibration set is worse than none.
      """

      accept [:use_case_id, :sample_size]

      change {PromptOn.Evals.Changes.SetActorId, attribute: :sampled_by}
      change PromptOn.Evals.CalibrationSet.Changes.SampleGenerations
    end

    update :archive do
      description "Soft archive. Drops out of `:latest_for_use_case`."
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    read :for_use_case do
      argument :use_case_id, :uuid, allow_nil?: false
      filter expr(use_case_id == ^arg(:use_case_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :latest_for_use_case do
      description "The newest set that has not been archived; nil when there is none."
      argument :use_case_id, :uuid, allow_nil?: false
      get? true

      filter expr(use_case_id == ^arg(:use_case_id) and is_nil(archived_at))
      prepare build(sort: [inserted_at: :desc], limit: 1)
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

    attribute :sample_size, :integer do
      description "How many samples were asked for."
      allow_nil? false
      public? true
      default 10
      constraints min: 1, max: 50
    end

    attribute :candidate_count, :integer do
      description "How many eligible logs the sampler saw (drives the empty-state copy)."
      public? true
      constraints min: 0
    end

    attribute :window_from, :utc_datetime_usec do
      description "`started_at` of the oldest sampled log."
      public? true
    end

    attribute :window_to, :utc_datetime_usec do
      description "`started_at` of the newest sampled log."
      public? true
    end

    attribute :sampled_by, :uuid do
      description "Soft ref to the User who sampled (User is outside the tenant, so no FK)."
      public? true
    end

    attribute :archived_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :use_case, PromptOn.Prompts.UseCase do
      allow_nil? false
      public? true
    end

    has_many :samples, PromptOn.Evals.CalibrationSample do
      sort position: :asc
      public? true
    end
  end

  calculations do
    calculate :archived?, :boolean, expr(not is_nil(archived_at))

    calculate :complete?,
              :boolean,
              expr(sample_count > 0 and sample_count == scored_sample_count) do
      description "Every sample has a human score — the gate on 'Draft rubric with AI'."
    end
  end

  aggregates do
    count :sample_count, :samples

    count :scored_sample_count, :samples do
      filter expr(not is_nil(user_score))
    end
  end
end
