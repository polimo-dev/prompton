defmodule PromptOn.Prompts.Prompt do
  @moduledoc """
  A **named prompt document** under a use case: one independently evolving version numbering
  (plan.md §5.5, ADR 0007). There can be more than one, such as per-language prompts (`"default"`,
  `"ko"`), so this layer exists; mixing them into one numbering would make diffs and history
  meaningless. There is no "head pointer" (the `latest_version_number` aggregate is enough).

  ## Mutable draft + immutable versions (ADR 0007 revised 2026-09-01)

  A prompt consists of **one auto-saved draft** (`:draft`) and **the immutable versions Deploy
  produced** (`PromptVersion`). Every editor edit flows through `:save_draft` (there is no save
  button and no commit message field), and an immutable version is born **only at the moment of
  Deploy**. When `:draft` is `nil`, the effective draft is the content of the latest version.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Prompts,
    fragments: [PromptOn.ProjectScoped]

  postgres do
    table "prompts"
  end

  actions do
    defaults [:read]

    create :open do
      description "Opens a new prompt under a use case. `(use_case, name)` is unique."
      accept [:use_case_id, :name, :description]
      validate PromptOn.Prompts.Prompt.Validations.UseCaseInTenant
    end

    update :rename do
      accept [:name, :description]
    end

    update :save_draft do
      description """
      The editor's **auto-save**: overwrites the draft slot with the whole edit buffer. No version
      is born (immutable versions are minted by Deploy). Passing `nil` clears the draft = returns to
      the latest version.
      """

      accept [:draft]
    end

    update :archive do
      description "Soft archive. Versions and logs remain."
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    read :active do
      filter expr(is_nil(archived_at))
    end

    read :for_use_case do
      argument :use_case_id, :uuid, allow_nil?: false
      filter expr(use_case_id == ^arg(:use_case_id) and is_nil(archived_at))
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass [PromptOn.Checks.ApiKeyActor, action_type(:read)] do
      description "An ApiKey reads only the non-archived prompts of its own project."
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

    attribute :name, :string, allow_nil?: false, public?: true, default: "default"
    attribute :description, :string, public?: true
    attribute :archived_at, :utc_datetime_usec, public?: true

    attribute :draft, :map do
      description """
      The auto-saved **mutable draft**. Same shape as what `PromptVersion` stores; it is jsonb, so
      the keys are strings:

          %{
            "engine" => "liquid" | "raw",
            "messages" => [%{"role" => "system" | "user" | "assistant", "content" => "...", "name" => nil}],
            "text_template" => "..." | nil
          }

      `kind :chat` uses `messages`, `kind :text` uses `text_template` (the same rule as versions).
      `nil` = no draft -> the effective draft is **the content of the latest version** (an empty
      document when there is no version either). Lint, `detected_variables` and `content_sha256`
      are not computed here; that is the job of the commit (= Deploy).
      """

      allow_nil? true
      public? true
      default nil
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :use_case, PromptOn.Prompts.UseCase do
      allow_nil? false
      public? true
    end

    has_many :versions, PromptOn.Prompts.PromptVersion do
      public? true
    end
  end

  calculations do
    calculate :archived?, :boolean, expr(not is_nil(archived_at))
  end

  aggregates do
    count :version_count, :versions
    max :latest_version_number, :versions, :number
  end

  identities do
    identity :unique_name_per_use_case, [:use_case_id, :name]
  end

  @doc """
  Edit buffer -> the map to store in the `:draft` slot. Exactly the shape `PromptVersion` stores,
  with string keys (it must be the same value after a jsonb round trip for "do not write if
  unchanged" to hold).
  """
  @spec draft_map(atom() | String.t(), [map()], String.t() | nil) :: map()
  def draft_map(engine, messages, text_template) do
    %{
      "engine" => to_string(engine || :liquid),
      "messages" => Enum.map(List.wrap(messages), &message_map/1),
      "text_template" => text_template
    }
  end

  @doc """
  `:draft` slot -> `%{engine: atom, messages: [%{role:, content:}], text_template:}`. `nil` when
  there is no draft (the caller falls back to the latest version).
  """
  @spec draft_content(map() | nil) ::
          %{engine: atom(), messages: [map()], text_template: String.t() | nil} | nil
  def draft_content(%{draft: draft}) when is_map(draft) do
    %{
      engine: draft_engine(Map.get(draft, "engine")),
      messages: draft |> Map.get("messages") |> List.wrap() |> Enum.map(&message_content/1),
      text_template: Map.get(draft, "text_template")
    }
  end

  def draft_content(_prompt), do: nil

  defp draft_engine("raw"), do: :raw
  defp draft_engine(_engine), do: :liquid

  defp message_content(message) do
    %{
      role: to_string(field(message, :role) || "user"),
      content: field(message, :content) || ""
    }
  end

  defp message_map(message) do
    %{
      "role" => to_string(field(message, :role) || "user"),
      "content" => field(message, :content) || "",
      "name" => field(message, :name)
    }
  end

  # Accepts both atom keys (a map from the form) and string keys (a map from jsonb).
  defp field(message, key) when is_map(message) do
    case Map.fetch(message, key) do
      {:ok, value} -> value
      :error -> Map.get(message, Atom.to_string(key))
    end
  end

  defp field(_message, _key), do: nil
end
