defmodule PromptOn.HeyDiaryImport.Spec do
  @moduledoc """
  The **knowledge baked into code** for the HeyDiary → PromptOn migration (plan.md §12.2 steps 4
  and 6, §12.3, §12.4):

  - The definitions of the 9 UseCases (kind / input_schema / source task).
  - The Liquid versions of the in-code user prompt templates (all of §12.3) — they render
    **byte-identical** to the HeyDiary originals (`open_router.ex`, `search_content.ex`,
    `transcript_revision.ex`, `chat_response.ex extraction_prompt`) (golden test).
  - The default temperature per calling method (`open_router.ex`: the 3 diary methods and
    `generate_text` 0.5, `remove_content_from_diary` 0.3, `infer_mood_from_diary` 0.1,
    `generate_chat_response` 0.7). HeyDiary uses `plan_ai_models.temperature ||
    ai_tasks.temperature || code default`; PromptOn collapses that into the single
    `params.temperature` of the Deployment **pin**.

  ## Template variables (the values the app passes as ctx)

  | UseCase | Variables |
  |---|---|
  | `diary_generation` | `mode` (`fresh`/`incremental`/`with_user_content`), `transcriptions[]`, `existing_diary`, `user_content` |
  | `diary_content_removal` | `current_diary`, `deleted_transcript` |
  | `mood_inference` | `diary_content` |
  | `diary_search_content` | `language`, `date`, `content` |
  | `transcript_revision` | `entities[]` (`%{name, content}`), `transcript` |
  | `memory_extraction` | `language`, `today`, `existing_memories[]` (`%{group_type, name, content}`), `conversation[]` (`%{role, content}`; the app applies the window and the user filter) |
  | `chat_response` | none — two stages (§12.3): only the system body lives in PromptOn, the app combines header/memories/tone |
  | `voice_transcription` | none — `text_template` = system_prompt |
  """

  @plan_source_task %{
    "diary_content_removal" => "diary_generation"
  }

  @doc """
  The list of UseCase definitions (import order is fixed). `source_task` is the HeyDiary task name
  from which `ai_tasks`/`plan_ai_models` are read (only `diary_content_removal` maps to
  `diary_generation`; `diary_embedding` has none).

  HeyDiary's "the user picks the model" trait (the chat model picker) is not in this table — with
  deployments becoming pins, the selectable target list is gone (ADR 0007 revision 2026-09-01).
  That task's non-default `plan_ai_models` rows survive only as a `{:plan_models_flattened, …}`
  warning.
  """
  @spec use_cases() :: [map()]
  def use_cases do
    [
      %{
        key: "voice_transcription",
        name: "Voice transcription",
        kind: :text,
        source_task: "voice_transcription",
        input_schema: [],
        description:
          "Groq whisper `prompt` (HeyDiary ai_tasks.voice_transcription system_prompt)."
      },
      %{
        key: "transcript_revision",
        name: "Transcript revision",
        kind: :chat,
        source_task: "transcript_revision",
        input_schema: [
          %{name: "entities", type: :list, required?: true},
          %{name: "transcript", type: :string, required?: true}
        ],
        description:
          "Transcript correction based on named entities (HeyDiary Workers.TranscriptRevision.build_prompt)."
      },
      %{
        key: "diary_generation",
        name: "Diary generation",
        kind: :chat,
        source_task: "diary_generation",
        input_schema: [
          %{name: "transcriptions", type: :list, required?: true},
          %{name: "mode", type: :string, required?: true},
          %{name: "existing_diary", type: :string, required?: false},
          %{name: "user_content", type: :string, required?: false}
        ],
        description:
          "A single prompt that branches on `mode` across the 3 diary generation modes (fresh/incremental/with_user_content) (plan.md §12.4)."
      },
      %{
        key: "diary_content_removal",
        name: "Diary content removal",
        kind: :chat,
        source_task: "diary_generation",
        input_schema: [
          %{name: "current_diary", type: :string, required?: true},
          %{name: "deleted_transcript", type: :string, required?: true}
        ],
        description:
          "Removes content that originated from a deleted recording. HeyDiary reused the diary_generation settings — the system prompt is copied at import (kept identical to diary_generation, plan.md §12.4)."
      },
      %{
        key: "mood_inference",
        name: "Mood inference",
        kind: :chat,
        source_task: "mood_inference",
        input_schema: [%{name: "diary_content", type: :string, required?: true}],
        description: "Diary → mood (-3..+3). Output parsing is the app's job."
      },
      %{
        key: "chat_response",
        name: "Chat response",
        kind: :chat,
        source_task: "chat_response",
        input_schema: [],
        description:
          "Chat response. In HeyDiary the user picked the model, but with deployments as pins there is one model (the choice is the app's job). Only the system body lives in PromptOn — the app combines header/memories/tone (plan.md §12.3 stage 2)."
      },
      %{
        key: "memory_extraction",
        name: "Memory extraction",
        kind: :chat,
        source_task: "memory_extraction",
        input_schema: [
          %{name: "language", type: :string, required?: true},
          %{name: "today", type: :string, required?: true},
          %{name: "existing_memories", type: :list, required?: true},
          %{name: "conversation", type: :list, required?: true}
        ],
        description:
          "Extracts long-term memories from a conversation (HeyDiary Workers.ChatResponse.extraction_prompt)."
      },
      %{
        key: "diary_search_content",
        name: "Diary search content",
        kind: :chat,
        source_task: "diary_search_content",
        input_schema: [
          %{name: "language", type: :string, required?: true},
          %{name: "date", type: :string, required?: true},
          %{name: "content", type: :string, required?: true}
        ],
        description: "Search summary (HeyDiary AI.SearchContent.generate)."
      },
      %{
        key: "diary_embedding",
        name: "Diary embedding",
        kind: :embedding,
        source_task: nil,
        input_schema: [],
        description:
          "Embedding logs only (not a resolve target — changing the model mixes pgvector dimensions, plan.md §12.1)."
      }
    ]
  end

  @doc "A UseCase definition (by key)."
  @spec use_case(String.t()) :: map() | nil
  def use_case(key), do: Enum.find(use_cases(), &(&1.key == key))

  @doc "UseCase key → HeyDiary source task name."
  @spec source_task(String.t()) :: String.t() | nil
  def source_task(key), do: Map.get(@plan_source_task, key, key)

  @doc "HeyDiary task name → the keys of the UseCases that use that task as their source."
  @spec use_case_keys_for_task(String.t()) :: [String.t()]
  def use_case_keys_for_task(task_name) do
    use_cases() |> Enum.filter(&(&1.source_task == task_name)) |> Enum.map(& &1.key)
  end

  # ---------------------------------------------------------------------------
  # Code default temperatures (the per-calling-method default_temperature in open_router.ex)

  @code_default_temperature %{
    "diary_generation" => 0.5,
    "diary_content_removal" => 0.3,
    "mood_inference" => 0.1,
    "chat_response" => 0.7,
    "transcript_revision" => 0.5,
    "diary_search_content" => 0.5,
    "memory_extraction" => 0.5
  }

  @doc """
  The UseCase's code default temperature (`open_router.ex`). `voice_transcription`/`diary_embedding`
  have no temperature (`nil`).
  """
  @spec code_default_temperature(String.t()) :: float() | nil
  def code_default_temperature(key), do: Map.get(@code_default_temperature, key)

  # ---------------------------------------------------------------------------
  # Groq / embedding models (hard-coded in HeyDiary)

  @doc "The Groq whisper model (HeyDiary.External.Groq `@model`)."
  def whisper_model,
    do: %{
      provider: :groq,
      model_id: "whisper-large-v3",
      display_name: "Whisper large v3",
      metadata: %{},
      provider_options: %{}
    }

  @doc "The embedding model (HeyDiary.External.Embeddings `@model`, via OpenRouter)."
  def embedding_model,
    do: %{
      provider: :openrouter,
      model_id: "openai/text-embedding-3-small",
      display_name: "OpenAI text-embedding-3-small",
      metadata: %{},
      provider_options: %{}
    }

  # ---------------------------------------------------------------------------
  # §12.3 user prompt templates (Liquid) — byte-identical to the HeyDiary originals

  # open_router.ex generate_diary_from_transcriptions / generate_diary_incremental /
  # generate_diary_with_user_content
  # numbered/1 = "#{index}. #{item}\n\n" repeated (including the trailing "\n\n").
  @diary_generation ~s|{% if mode == "incremental" %}Here is the existing diary entry:
---
{{ existing_diary }}
---

Here are new voice transcriptions to incorporate:
{% for t in transcriptions %}{{ forloop.index }}. {{ t }}

{% endfor %}
Merge the new content into the existing diary naturally. Keep the existing content and style intact.{% elsif mode == "with_user_content" %}The user has written/edited their diary entry as follows:
---
{{ user_content }}
---

Here are all the voice transcriptions for the day:
{% for t in transcriptions %}{{ forloop.index }}. {{ t }}

{% endfor %}
Regenerate the diary entry. Preserve the user's manually written content and style as much as possible, while incorporating information from the voice transcriptions.{% else %}Please write a diary entry based on these voice transcriptions:

{% for t in transcriptions %}{{ forloop.index }}. {{ t }}

{% endfor %}{% endif %}|

  # open_router.ex remove_content_from_diary
  @diary_content_removal ~s|[Current Diary]
{{ current_diary }}

[Deleted Recording Transcript]
{{ deleted_transcript }}

Remove content from the diary that originated from the deleted recording transcript. Keep all other content intact. Return the updated diary.|

  # open_router.ex infer_mood_from_diary
  @mood_inference ~s|Analyze this diary entry and return only the mood level (-3 to +3):

{{ diary_content }}|

  # ai/search_content.ex SearchContent.generate
  @diary_search_content ~s|[Output Language: {{ language }}]
Date: {{ date }}

{{ content }}|

  # workers/transcript_revision.ex build_prompt — entity_lines = "- #{name}: #{content}\n" repeated
  @transcript_revision ~s|[Named Entities]
{% for e in entities %}- {{ e.name }}: {{ e.content }}
{% endfor %}
[Transcript]
{{ transcript }}|

  # workers/chat_response.ex extraction_prompt — the "[Conversation]" header only when there are
  # existing memories (Go behaviour preserved)
  @memory_extraction ~s|[Output Language: {{ language }}]
[Current Date: {{ today }}]

{% if existing_memories.size > 0 %}[Existing Memories - DO NOT extract these again]
{% for m in existing_memories %}{% if m.group_type == "named_entity" and m.name %}- [named_entity] {{ m.name }}: {{ m.content }}
{% else %}- [user_info] {{ m.content }}
{% endif %}{% endfor %}
[Conversation]
{% endif %}{% for m in conversation %}{{ m.role }}: {{ m.content }}
{% endfor %}|

  @user_templates %{
    "diary_generation" => @diary_generation,
    "diary_content_removal" => @diary_content_removal,
    "mood_inference" => @mood_inference,
    "diary_search_content" => @diary_search_content,
    "transcript_revision" => @transcript_revision,
    "memory_extraction" => @memory_extraction
  }

  @doc """
  The UseCase's user-message Liquid template (§12.3). `nil` for `chat_response` (system only),
  `voice_transcription` (text) and `diary_embedding`.
  """
  @spec user_template(String.t()) :: String.t() | nil
  def user_template(key), do: Map.get(@user_templates, key)

  @doc "The keys of the UseCases that have a user template."
  @spec templated_use_case_keys() :: [String.t()]
  def templated_use_case_keys, do: @user_templates |> Map.keys() |> Enum.sort()

  # ---------------------------------------------------------------------------
  # System prompt escaping

  @doc """
  Makes a HeyDiary system prompt original safe as a Liquid template. When the original contains
  `{{`/`{%`, they are replaced with Liquid literal output (`{{ "{{" }}`, `{{ "{%" }}`) so that the
  rendered result stays byte-identical to the original — the engine is per version, so leaving it
  as `:raw` would make the user template of the same version unrenderable.

  Returns `{:ok, template}` (rendered result == original verified + `PromptOnSDK.Template.lint/1`
  passes) or `{:error, reason}`.
  """
  @spec escape_literal(String.t()) :: {:ok, String.t()} | {:error, term()}
  def escape_literal(source) when is_binary(source) do
    escaped =
      source
      |> String.replace("{{", ~s|{{ "{{" }}|)
      |> String.replace("{%", ~s|{{ "{%" }}|)

    with :ok <- PromptOnSDK.Template.lint(escaped),
         {:ok, ^source} <- PromptOnSDK.Template.render(escaped, %{}) do
      {:ok, escaped}
    else
      {:ok, other} -> {:error, {:render_mismatch, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
