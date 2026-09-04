defmodule PromptOn.Prompts.UseCase do
  @moduledoc """
  A use case = "one LLM call site" of the app (plan.md §5.5, the place of HeyDiary's `ai_tasks`).
  `key` (`support_reply`) is the SDK contract, so it is stored without normalization via
  `@raw_string`.

  - `kind` is `:chat` (a message array template) | `:text` (a single string, the Groq STT `prompt`)
    | `:embedding` (no prompt, logs only).
  - `:define` creates `Prompt(name: "default")` in the same transaction for `:chat`/`:text` only.
    One Prompt per use case is the norm, so the UI hides that layer.
  - `default_params` is the base under the `params` of a Deployment target (HeyDiary
    `ai_tasks.temperature`); a `nil` `payload_policy` inherits the Project value.
  - `selection_mode` was deleted (ADR 0007): user selection is expressed as multiple targets of a
    Deployment rule.
  - Generation-based aggregates/calculations (`generation_count_24h`, `error_rate_24h`) are added
    when needed.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Prompts,
    fragments: [PromptOn.ProjectScoped]

  @raw_string [allow_empty?: true, trim?: false]

  postgres do
    table "use_cases"
  end

  actions do
    defaults [:read]

    create :define do
      description "Defines a use case. chat/text also get the default Prompt `default`."

      accept [
        :key,
        :name,
        :description,
        :kind,
        :input_schema,
        :default_params,
        :payload_policy,
        :tags
      ]

      change PromptOn.Prompts.UseCase.Changes.CreateDefaultPrompt
    end

    update :describe do
      accept [:name, :description, :tags]
    end

    update :set_input_schema do
      require_atomic? false
      accept [:input_schema]
    end

    update :set_default_params do
      description "Replaces the base parameters under a Deployment target's params (not a merge)."
      accept [:default_params]
    end

    update :set_payload_policy do
      description "Overrides the raw payload storage policy. `nil` inherits the Project default."
      require_atomic? false
      accept [:payload_policy]
    end

    update :set_arena_models do
      description """
      Replaces the set of arena columns (not a merge). The screen's columns are **exactly this
      list**: removing one makes the column disappear (the log stays in `ArenaMessage` untouched)
      and adding it back brings it back together with the past conversation.
      """

      accept [:arena_model_ids]
    end

    update :archive do
      description "Soft archive. Dropped from snapshots and lists."
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    read :by_key do
      argument :key, :string, allow_nil?: false
      get? true
      filter expr(key == ^arg(:key))
    end

    read :active do
      filter expr(is_nil(archived_at))
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass [PromptOn.Checks.ApiKeyActor, action_type(:read)] do
      description "An ApiKey reads only the non-archived use cases of its own project."
      authorize_if expr(project_id == ^actor(:project_id) and is_nil(archived_at))
    end

    policy [PromptOn.Checks.ApiKeyActor, action_type([:create, :update, :destroy])] do
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

    attribute :key, :string do
      description "Name the SDK uses (`support_reply`). Lowercase letters, digits, underscores."
      allow_nil? false
      public? true
      constraints @raw_string ++ [match: ~r/^[a-z][a-z0-9_]*$/]
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :chat
      constraints one_of: [:chat, :text, :embedding]
    end

    attribute :input_schema, {:array, PromptOn.Prompts.Variable} do
      allow_nil? false
      public? true
      default []
    end

    attribute :default_params, :map, allow_nil?: false, public?: true, default: %{}

    attribute :payload_policy, PromptOn.Observability.PayloadPolicy do
      description "nil inherits Project.payload_policy."
      public? true
    end

    attribute :tags, {:array, :string}, allow_nil?: false, public?: true, default: []

    attribute :arena_model_ids, {:array, :uuid} do
      description """
      Ids of the models shown as columns in the arena (the use case screen chat); the order chosen
      is the order of the columns on screen. The `ArenaMessage` log is independent of this list, so
      the conversation of a removed model is not deleted and comes back when it is chosen again.
      """

      allow_nil? false
      public? true
      default []
    end

    attribute :archived_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :prompts, PromptOn.Prompts.Prompt do
      public? true
    end
  end

  calculations do
    calculate :archived?, :boolean, expr(not is_nil(archived_at))
  end

  aggregates do
    count :prompt_count, :prompts do
      filter expr(is_nil(archived_at))
    end
  end

  identities do
    identity :unique_key_per_project, [:project_id, :key]
  end
end
