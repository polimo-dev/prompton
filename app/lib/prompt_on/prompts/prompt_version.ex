defmodule PromptOn.Prompts.PromptVersion do
  @moduledoc """
  An **immutable version** of a prompt (ADR 0007). Deployment pins and Generations point at it by
  id, so its content never changes:

  - **No state machine.** Like a git commit it is immutable from birth: the verb "publish" is gone,
    and "a deployed version" is not a status but the fact *that a Deployment references it*.
  - **Only `Deploy` gives birth to versions** (ADR 0007 revised 2026-09-01). Editor edits are
    auto-saved to `Prompt.draft`, and Deploy mints that draft with `:commit`. If the draft equals
    the latest version it is not minted; that version is reused (no two versions with the same
    content).
  - The only actions that accept content are `:commit`/`:fork`, and both are **create**. There is
    no update action.
  - `number` increases monotonically within a Prompt: `:commit/:fork` lock the Prompt row
    `FOR UPDATE` and then assign `max+1` (`Changes.AssignNumber`); the identity
    `:unique_number_per_prompt` is the last line of defense.
  - On save, `PromptOnSDK.Template.lint/1` enforces the P0 whitelist (tags for/if/unless/assign,
    filters size/join/default, no whitespace control) and `detected_variables` and `content_sha256`
    are computed, using the same code as the SDK.
  - `tools` is a P2 reserved column; no action accepts it.
  - An ApiKey (`:resolve`) reads the versions of its own project **without a gate**: what is live
    is decided by the Deployment.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Prompts,
    fragments: [PromptOn.ProjectScoped]

  alias PromptOn.Prompts.PromptVersion.{Calculations, Changes, Validations}

  @raw_string [allow_empty?: true, trim?: false]

  postgres do
    table "prompt_versions"
  end

  actions do
    defaults [:read]

    create :commit do
      description """
      **Commits the draft as a new immutable version** (minted by the editor's Deploy). Assigns the
      next number within the Prompt and lints/parses the templates. Every call creates a new
      version; there is no action that modifies an existing one.
      """

      accept [:prompt_id, :engine, :messages, :text_template, :commit_message]
      change Changes.SetAuthor
      validate Validations.ContentMatchesKind
      validate Validations.LintTemplates
      change Changes.ComputeDerived
      change Changes.AssignNumber
    end

    create :fork do
      description """
      Copies the content of an existing version (`source_version_id`) and commits it as a new
      version: into the prompt given by `prompt_id`, or into the source's own prompt at the next
      number when absent. The source is kept in `parent_version_id`.
      """

      argument :source_version_id, :uuid, allow_nil?: false
      argument :prompt_id, :uuid
      accept [:commit_message]
      change Changes.CopyFromSource
      change Changes.SetAuthor
      validate Validations.ContentMatchesKind
      change Changes.ComputeDerived
      change Changes.AssignNumber
    end

    read :for_prompt do
      argument :prompt_id, :uuid, allow_nil?: false
      filter expr(prompt_id == ^arg(:prompt_id))
      prepare build(sort: [number: :desc])
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass [PromptOn.Checks.ApiKeyActor, action_type(:read)] do
      description """
      An ApiKey reads the versions of its own project (tenant-pinned). There is no published gate:
      what is live is decided by the Deployment.
      """

      authorize_if expr(project_id == ^actor(:project_id))
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

    attribute :number, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :engine, :atom do
      allow_nil? false
      public? true
      default :liquid
      constraints one_of: [:liquid, :raw]
    end

    attribute :messages, {:array, PromptOn.Prompts.MessageTemplate} do
      description "The kind :chat template. Empty array for :text."
      allow_nil? false
      public? true
      default []
    end

    attribute :text_template, :string do
      description "The kind :text template (e.g. the Groq STT `prompt`). nil for :chat."
      public? true
      constraints @raw_string
    end

    attribute :detected_variables, {:array, :string} do
      description "Top-level input variables pulled from the templates on save (sorted, unique)."
      allow_nil? false
      public? true
      default []
    end

    attribute :commit_message, :string, public?: true
    attribute :author_id, :uuid, public?: true
    attribute :content_sha256, :string, allow_nil?: false, public?: true

    attribute :tools, :map do
      description "Reserved for P2 (versioning of tool definitions). No action accepts it."
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :prompt, PromptOn.Prompts.Prompt do
      allow_nil? false
      public? true
    end

    belongs_to :parent_version, __MODULE__ do
      description "The fork source."
      public? true
    end
  end

  calculations do
    calculate :variable_names, {:array, :string}, expr(detected_variables)

    calculate :missing_in_schema, {:array, :string}, Calculations.MissingInSchema do
      description "Template variables minus the UseCase.input_schema names (for UI warnings)."
    end
  end

  identities do
    identity :unique_number_per_prompt, [:prompt_id, :number]
  end

  @doc """
  The canonical serialization the content hash is computed over. Messages become an array of
  `[role, name, content]` arrays (key order irrelevant), text_template is taken as is. The engine
  is included (the same source text is a different contract under raw vs liquid).
  """
  @spec canonical_content(atom() | String.t(), [map()], String.t() | nil) :: String.t()
  def canonical_content(engine, messages, text_template) do
    Jason.encode!([
      to_string(engine),
      Enum.map(messages || [], fn m ->
        [to_string(field(m, :role)), field(m, :name), field(m, :content)]
      end),
      text_template
    ])
  end

  @doc "sha256 hex of the canonical serialization."
  @spec content_hash(atom() | String.t(), [map()], String.t() | nil) :: String.t()
  def content_hash(engine, messages, text_template) do
    :crypto.hash(:sha256, canonical_content(engine, messages, text_template))
    |> Base.encode16(case: :lower)
  end

  defp field(m, key) when is_map(m), do: Map.get(m, key) || Map.get(m, Atom.to_string(key))
end
