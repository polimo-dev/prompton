defmodule PromptOn.Prompts do
  @moduledoc """
  Domain of use cases (UseCase), prompt documents (Prompt) and immutable versions (PromptVersion)
  (ADR 0007).

  There are only three nouns: Variant was deleted (a prompt + model combination is the pin of a
  Deployment revision) and versions have no state machine (`:commit`, immutable from birth, minted
  by the editor's Deploy). Deployments have a different policy character (an ApiKey only reads), so
  they are split off into `PromptOn.Deployments`. Every resource is inside the tenant
  (`project_id`).

  There is one more screen companion here: `ArenaMessage` (the persistent conversation log of the
  arena on the use case screen, on the `(use case x model)` axis). It is console-only, so an ApiKey
  cannot access it.
  """

  use Ash.Domain,
    otp_app: :prompton,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource PromptOn.Prompts.UseCase do
      define :define_use_case, action: :define
      define :get_use_case, action: :read, get_by: [:id], not_found_error?: false
      define :get_use_case_by_key, action: :by_key, args: [:key], not_found_error?: false
      define :list_use_cases, action: :active
      define :list_all_use_cases, action: :read
      define :describe_use_case, action: :describe
      define :set_use_case_input_schema, action: :set_input_schema
      define :set_use_case_default_params, action: :set_default_params
      define :set_use_case_payload_policy, action: :set_payload_policy
      define :set_use_case_arena_models, action: :set_arena_models
      define :archive_use_case, action: :archive
    end

    resource PromptOn.Prompts.Prompt do
      define :open_prompt, action: :open
      define :get_prompt, action: :read, get_by: [:id], not_found_error?: false
      define :list_prompts, action: :for_use_case, args: [:use_case_id]
      define :rename_prompt, action: :rename
      define :save_prompt_draft, action: :save_draft
      define :archive_prompt, action: :archive
    end

    resource PromptOn.Prompts.PromptVersion do
      define :commit_prompt_version, action: :commit
      define :fork_prompt_version, action: :fork, args: [:source_version_id]
      define :get_prompt_version, action: :read, get_by: [:id], not_found_error?: false
      define :list_prompt_versions, action: :for_prompt, args: [:prompt_id]
    end

    resource PromptOn.Prompts.ArenaMessage do
      define :append_arena_message, action: :append

      # `model_id` is not a positional argument: the last positional argument and the opts keyword
      # cannot be told apart, so a call `f(use_case_id, opts)` would swallow opts as model_id. Pass
      # it in the params map:
      # `arena_messages_for_use_case(uc_id, %{model_id: id}, tenant: ..., actor: ...)`.
      define :arena_messages_for_use_case, action: :for_use_case, args: [:use_case_id]

      # Bulk destroy without record references: with `require_reference?: false` the code interface
      # folds the action arguments into the query filter and runs `Ash.bulk_destroy` once. Returns
      # `%Ash.BulkResult{}`. To clear only one model column, call
      # `clear_arena(uc_id, %{model_id: id}, opts)`.
      define :clear_arena, action: :prune, args: [:use_case_id], require_reference?: false
    end
  end
end
