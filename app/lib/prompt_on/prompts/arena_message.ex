defmodule PromptOn.Prompts.ArenaMessage do
  @moduledoc """
  The **arena** conversation log of the use case screen: an append-only table that grows along the
  `(use_case x model)` axis.

  The arena is a screen where one send goes out to every selected model at once, and that
  conversation must survive leaving the screen (reopening it shows the past inputs and answers as
  they were). So it is rows inside the tenant, not session state.

  - `role` is `:user` (the sent input) | `:assistant` (the model's answer). Even a user turn is
    **one row per model**: each column is an independent conversation, so wiping one model later
    (`:prune` + `model_id`) leaves the other histories intact.
  - An assistant turn with `status :error` fills `error_message` and has an empty string `content`.
  - `prompt_version_number` is the number of the prompt version that produced the answer (a hint
    for the snapshot, nullable). It is a number rather than a version id because the screen shows
    "the line answered with v3" as is.
  - `latency_ms`/`input_tokens`/`output_tokens`/`cost_usd` are observations filled in when
    available. The official log is `PromptOn.Observability.Generation`; this table is **for
    restoring the screen**, so it is not tied to it by FK.
  - `author_id` is the sending user (nullable, soft ref). User is outside the tenant, so no FK.
  - Policy: console-only. **An ApiKey can neither read nor write** (the SDK contract has no arena).
    Writes are Forbidden; reads are always an empty list because Ash folds the policy into a
    filter. Unlike other resources there is no ApiKey read bypass.

  ## Clearing (bulk destroy)

  `destroy :prune` is an **atomic bulk destroy** action that folds its arguments (`use_case_id`,
  optional `model_id`) into the query with `change filter(...)`. The domain code interface is
  defined with `require_reference?: false`, so it deletes with a single `Ash.bulk_destroy` without
  reading the records first; that is the standard form of "bulk delete without record references"
  in Ash 3. It returns `%Ash.BulkResult{}` (`status: :success | :error`).

      # clear the whole use case
      PromptOn.Prompts.clear_arena(use_case.id, tenant: project.id, actor: user)
      # one model column only (model_id goes in the params map: a last positional argument cannot be
      # told apart from opts)
      PromptOn.Prompts.clear_arena(use_case.id, %{model_id: model.id}, tenant: project.id, actor: user)

  Reads have the same shape:
  `arena_messages_for_use_case(use_case_id, %{model_id: id} \\\\ %{}, opts)`.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Prompts,
    fragments: [PromptOn.ProjectScoped]

  @raw_string [allow_empty?: true, trim?: false]

  @roles [:user, :assistant]
  @statuses [:ok, :error]

  postgres do
    table "arena_messages"

    references do
      reference :use_case, on_delete: :delete
      reference :model, on_delete: :delete
    end

    custom_indexes do
      index [:project_id, :use_case_id, :model_id, :inserted_at, :id],
        name: "arena_messages_use_case_model_index"
    end
  end

  actions do
    defaults [:read]

    create :append do
      description """
      Appends one line to the arena. The same action serves a user turn and a model answer (told
      apart by `role`).
      """

      accept [
        :use_case_id,
        :model_id,
        :role,
        :content,
        :status,
        :error_message,
        :prompt_version_number,
        :params,
        :latency_ms,
        :input_tokens,
        :output_tokens,
        :cost_usd,
        :author_id
      ]
    end

    read :for_use_case do
      description """
      The whole arena log of one use case (only that column when the model argument is given). Sort
      is `inserted_at asc, id asc`: with a uuid_v7 PK, rows that landed in the same microsecond are
      still stably ordered by insertion.
      """

      argument :use_case_id, :uuid, allow_nil?: false
      argument :model_id, :uuid

      filter expr(
               use_case_id == ^arg(:use_case_id) and
                 (is_nil(^arg(:model_id)) or model_id == ^arg(:model_id))
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    destroy :prune do
      description """
      Clears the arena of one use case (only that model column when `model_id` is given). It is an
      atomic bulk delete that folds the arguments into the query filter, so the domain calls it
      through a `require_reference?: false` code interface.
      """

      argument :use_case_id, :uuid, allow_nil?: false
      argument :model_id, :uuid

      change filter(
               expr(
                 use_case_id == ^arg(:use_case_id) and
                   (is_nil(^arg(:model_id)) or model_id == ^arg(:model_id))
               )
             )
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy PromptOn.Checks.ApiKeyActor do
      description """
      The arena is console-only: an ApiKey can neither read nor write (not in the SDK contract).
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

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: @roles
    end

    attribute :content, :string do
      description "Stored verbatim (empty string allowed: an error answer has no content)."
      allow_nil? false
      public? true
      default ""
      constraints @raw_string
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :ok
      constraints one_of: @statuses
    end

    attribute :error_message, :string, public?: true

    attribute :prompt_version_number, :integer do
      description "Prompt version number behind this answer; nil for user turns or when unrecorded."
      public? true
      constraints min: 1
    end

    attribute :params, :map, allow_nil?: false, public?: true, default: %{}

    attribute :latency_ms, :integer, public?: true, constraints: [min: 0]
    attribute :input_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :output_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :cost_usd, :decimal, public?: true

    attribute :author_id, :uuid do
      description "The sending user (soft ref: User is outside the tenant, so no FK)."
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :use_case, PromptOn.Prompts.UseCase do
      allow_nil? false
      public? true
    end

    belongs_to :model, PromptOn.Catalog.Model do
      allow_nil? false
      public? true
    end
  end

  @doc "Allowed role values."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "Allowed status values."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
