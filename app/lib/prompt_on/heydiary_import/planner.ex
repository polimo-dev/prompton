defmodule PromptOn.HeyDiaryImport.Planner do
  @moduledoc """
  Dump (`PromptOn.HeyDiaryImport.Dump`) → migration plan (`PromptOn.HeyDiaryImport.Plan`). Pure
  functions, no DB, deterministic (the same dump and options give the same plan).

  Computes plan.md §12.2 steps 2-7 under the ADR 0007 (+ revision 2026-09-01 "deployments are
  pins") model:

  - **Model**: `ai_models` row → `provider :openrouter`, `model_id = model`,
    `metadata %{description_key}`, `provider_options %{"only" => providers}` (`providers` NULL →
    `%{"only" => nil}`, `[]` → `%{"only" => []}` — the contract under which HeyDiary sent
    `provider.only: null`/`[]` as is). Plus the Groq whisper and embedding models.
  - **UseCase**: the 9 of `Spec.use_cases/0`. `default_params.temperature` = the temperature of
    the source task's common (NULL-language) row (when present).
  - **Prompt/PromptVersion**: per (task × language) a Prompt `default` (NULL) / `<language>` with
    one committed version — `messages = [system: original (escaped), user: §12.3 Liquid template]`,
    `voice_transcription` uses `text_template`, `chat_response` is system only,
    `diary_content_removal` copies the `diary_generation` rows + the removal template. The engine
    is always `:liquid` — `{{`/`{%` in the original are turned into literal output by
    `Spec.escape_literal/1`.
  - **Deployment**: **one** per use case (`use_case × production`), and it is **one pin**:
    - model = the model of the **free (= common) default row** of `plan_ai_models`
      (`pinned_plan_model/2`). The per-plan model hierarchy cannot be represented because a
      revision holds one model — the other rows are dropped and `{:plan_models_flattened, …}`
      reports it (plan differentiation is the app's job).
    - `params.temperature = coalesce(pm.temperature, ai_tasks common-row temperature, code
      default)`, `provider_options %{"allow_fallbacks" => pm.allow_fallbacks}`.
    - `prompt_names` = **every** prompt name of that use case (`default` + the languages). All of
      them are pinned.

  See the `PromptOn.HeyDiaryImport.Plan` moduledoc for the list of warnings.
  """

  alias PromptOn.HeyDiaryImport.{Dump, Plan, Spec}

  @default_project_slug "heydiary"
  @default_project_name "HeyDiary"
  @default_environment "production"

  @doc """
  Builds the plan. `opts`: `:project_slug` (default `"heydiary"`), `:project_name` (default
  `"HeyDiary"`), `:environment` (default `"production"`).
  """
  @spec plan(Dump.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(%Dump{} = dump, opts \\ []) do
    project = %{
      slug: Keyword.get(opts, :project_slug, @default_project_slug),
      name: Keyword.get(opts, :project_name, @default_project_name)
    }

    environment = Keyword.get(opts, :environment, @default_environment)

    acc = %Plan{project: project, environment: environment, models: models(dump)}

    Spec.use_cases()
    |> Enum.reduce_while({:ok, acc}, fn spec, {:ok, acc} ->
      case plan_use_case(dump, spec, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, plan} -> {:ok, finalize(plan, dump)}
      error -> error
    end
  end

  @doc """
  The `plan_ai_models` row that becomes the pin — the free-level default row, else the default row
  of the lowest level, else the first row when there is no default row at all. `Verify` must use
  the same function when computing the HeyDiary side (the pin and the comparison baseline must not
  diverge). `nil` when `plan_models` is empty.
  """
  @spec pinned_plan_model(Dump.t(), String.t()) :: Dump.plan_model() | nil
  def pinned_plan_model(%Dump{} = dump, task_name) do
    dump |> Dump.plan_models(task_name) |> pick_plan_model() |> elem(0)
  end

  # ---------------------------------------------------------------------------
  # models

  defp models(dump) do
    from_dump =
      Enum.map(dump.ai_models, fn m ->
        %{
          provider: :openrouter,
          model_id: m.model,
          display_name: m.display_name,
          metadata: %{"description_key" => m.description_key},
          provider_options: %{"only" => m.providers},
          source_id: m.id
        }
      end)

    extra =
      Enum.map([Spec.whisper_model(), Spec.embedding_model()], &Map.put(&1, :source_id, nil))

    (from_dump ++ extra)
    |> Enum.uniq_by(&{&1.provider, &1.model_id})
  end

  # ---------------------------------------------------------------------------
  # use cases

  defp plan_use_case(dump, spec, acc) do
    use_case = %{
      key: spec.key,
      name: spec.name,
      kind: spec.kind,
      input_schema: spec.input_schema,
      default_params: default_params(dump, spec),
      description: spec.description
    }

    acc = %{acc | use_cases: acc.use_cases ++ [use_case]}

    case spec.kind do
      :embedding -> {:ok, plan_embedding(spec, acc)}
      :text -> plan_text(dump, spec, acc)
      :chat -> plan_chat(dump, spec, acc)
    end
  end

  defp default_params(_dump, %{source_task: nil}), do: %{}

  defp default_params(dump, %{source_task: task}) do
    case Dump.task(dump, task, nil) do
      %{temperature: t} when is_float(t) -> %{"temperature" => t}
      _ -> %{}
    end
  end

  # diary_embedding: no prompt — only the model is pinned (the pins map is empty).
  defp plan_embedding(spec, acc) do
    model = Spec.embedding_model()

    deployment = %{
      use_case_key: spec.key,
      model: {model.provider, model.model_id},
      params: %{},
      provider_options: %{},
      prompt_names: [],
      description: "HeyDiary.External.Embeddings @model (logs only)"
    }

    %{acc | deployments: acc.deployments ++ [deployment]}
  end

  # voice_transcription: text_template = system_prompt, and the model is Groq whisper (there are no
  # plan_ai_models rows).
  defp plan_text(dump, spec, acc) do
    rows = Dump.task_rows(dump, spec.source_task)
    whisper = Spec.whisper_model()

    if rows == [] do
      {:ok, warn(acc, {:missing_task, spec.key, spec.source_task})}
    else
      with {:ok, versions} <- text_versions(spec, rows) do
        deployment = %{
          use_case_key: spec.key,
          model: {whisper.provider, whisper.model_id},
          params: %{},
          provider_options: %{},
          prompt_names: prompt_names(rows),
          description: "HeyDiary.External.Groq @model"
        }

        acc =
          acc
          |> add_prompts(spec, rows, versions)
          |> maybe_warn_no_default_prompt(spec, rows)
          |> Map.update!(:deployments, &(&1 ++ [deployment]))

        {:ok, acc}
      end
    end
  end

  defp text_versions(spec, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case Spec.escape_literal(row.system_prompt) do
        {:ok, text} ->
          version = %{
            use_case_key: spec.key,
            prompt_name: prompt_name(row.language),
            engine: :liquid,
            messages: [],
            text_template: text,
            commit_message: commit_message(row)
          }

          {:cont, {:ok, acc ++ [version]}}

        {:error, reason} ->
          {:halt, {:error, {:unescapable_system_prompt, row.task_name, row.language, reason}}}
      end
    end)
  end

  # chat kind: transcript_revision / diary_generation / diary_content_removal / mood_inference / chat_response /
  # memory_extraction / diary_search_content
  defp plan_chat(dump, spec, acc) do
    rows = Dump.task_rows(dump, spec.source_task)
    plan_models = Dump.plan_models(dump, spec.source_task)

    if rows == [] do
      {:ok, warn(acc, {:missing_task, spec.key, spec.source_task})}
    else
      with {:ok, versions} <- chat_versions(spec, rows) do
        acc =
          acc
          |> add_prompts(spec, rows, versions)
          |> maybe_warn_no_default_prompt(spec, rows)

        if plan_models == [] do
          {:ok, warn(acc, {:no_plan_models, spec.key})}
        else
          {pin, reason} = pick_plan_model(plan_models)

          deployment = %{
            use_case_key: spec.key,
            model: {:openrouter, pin.model},
            params: params(spec, rows, pin),
            provider_options: %{"allow_fallbacks" => pin.allow_fallbacks},
            prompt_names: prompt_names(rows),
            description:
              "HeyDiary plan_ai_models #{pin.id} (#{pin.plan}#{if pin.is_default, do: ", default", else: ""})"
          }

          acc =
            acc
            |> maybe_warn(reason, spec, pin)
            |> warn_flattened_plan_models(spec, plan_models, pin)
            |> warn_ambiguous_default(dump, spec, pin)
            |> warn_language_temperatures(spec, rows, pin)
            |> Map.update!(:deployments, &(&1 ++ [deployment]))

          {:ok, acc}
        end
      end
    end
  end

  defp chat_versions(spec, rows) do
    user_template = Spec.user_template(spec.key)

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case Spec.escape_literal(row.system_prompt) do
        {:ok, system} ->
          messages =
            [%{role: :system, content: system}] ++
              if(is_nil(user_template), do: [], else: [%{role: :user, content: user_template}])

          version = %{
            use_case_key: spec.key,
            prompt_name: prompt_name(row.language),
            engine: :liquid,
            messages: messages,
            text_template: nil,
            commit_message: commit_message(row)
          }

          {:cont, {:ok, acc ++ [version]}}

        {:error, reason} ->
          {:halt, {:error, {:unescapable_system_prompt, row.task_name, row.language, reason}}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # pin selection

  # Free-level default row → default row of the lowest level → first row. The second and third
  # branches produce a warning.
  defp pick_plan_model([]), do: {nil, nil}

  defp pick_plan_model(plan_models) do
    defaults = Enum.filter(plan_models, & &1.is_default)

    cond do
      pm = free_default(defaults) -> {pm, nil}
      pm = lowest_level(defaults) -> {pm, :no_free_default}
      true -> {hd(plan_models), :no_free_default}
    end
  end

  # Must pick the same row as `Dump.default_plan_model(dump, "free", task, _)` (level-0 rows in
  # insertion order).
  defp free_default(defaults) do
    defaults
    |> Enum.filter(&(Dump.plan_level(&1.plan) == 0))
    |> Enum.sort_by(&{&1.created_at || "", &1.id})
    |> List.first()
  end

  defp lowest_level([]), do: nil

  defp lowest_level(plan_models),
    do: Enum.min_by(plan_models, &{Dump.plan_level(&1.plan), &1.created_at || "", &1.id})

  # HeyDiary uses `pam.temperature || ai_tasks.temperature || code default`, where `ai_tasks` is
  # the common (NULL-language) row — a revision has a single `params`, so per-language
  # temperatures collapse (see the warning).
  defp params(spec, rows, pin) do
    common = Enum.find(rows, &is_nil(&1.language)) || hd(rows)

    temperature =
      pin.temperature || common.temperature || Spec.code_default_temperature(spec.key)

    if is_nil(temperature), do: %{}, else: %{"temperature" => temperature}
  end

  # ---------------------------------------------------------------------------
  # warnings

  defp warn(acc, warning), do: %{acc | warnings: acc.warnings ++ [warning]}

  defp maybe_warn(acc, nil, _spec, _pin), do: acc

  defp maybe_warn(acc, :no_free_default, spec, pin),
    do: warn(acc, {:no_free_default, spec.key, pin.plan})

  defp maybe_warn_no_default_prompt(acc, spec, rows) do
    if Enum.any?(rows, &is_nil(&1.language)) do
      acc
    else
      warn(acc, {:no_default_prompt, spec.key, Enum.map(rows, & &1.language)})
    end
  end

  # The plans of the rows that did not become the pin (lowest level first). Surfaces the fact that
  # per-plan model differentiation is lost.
  defp warn_flattened_plan_models(acc, spec, plan_models, pin) do
    dropped =
      plan_models
      |> Enum.reject(&(&1.id == pin.id))
      |> Enum.map(& &1.plan)
      |> Enum.uniq()
      |> Enum.sort_by(&Dump.plan_level/1)

    if dropped == [], do: acc, else: warn(acc, {:plan_models_flattened, spec.key, dropped})
  end

  # At the pinned level, do the HeyDiary Registry (insertion order) and this tool (highest plan
  # first) pick differently?
  defp warn_ambiguous_default(acc, dump, spec, pin) do
    insertion = Dump.default_plan_model(dump, pin.plan, spec.source_task, :insertion_order)
    highest = Dump.default_plan_model(dump, pin.plan, spec.source_task, :highest_plan)

    if insertion && highest && insertion.id != highest.id do
      warn(
        acc,
        {:ambiguous_default, spec.key, pin.plan,
         %{insertion_order: insertion.model, highest_plan: highest.model}}
      )
    else
      acc
    end
  end

  # When `plan_ai_models.temperature` is set it wins regardless of language — nothing is lost then.
  defp warn_language_temperatures(acc, _spec, _rows, %{temperature: t}) when not is_nil(t),
    do: acc

  defp warn_language_temperatures(acc, spec, rows, _pin) do
    per_language =
      Map.new(rows, fn row ->
        {row.language || "default", row.temperature || Spec.code_default_temperature(spec.key)}
      end)

    if per_language |> Map.values() |> Enum.uniq() |> length() > 1 do
      warn(acc, {:language_temperatures_flattened, spec.key, per_language})
    else
      acc
    end
  end

  defp finalize(plan, dump) do
    known = Spec.use_cases() |> Enum.map(& &1.source_task) |> Enum.reject(&is_nil/1)

    unknown =
      dump
      |> Dump.task_names()
      |> Enum.reject(&(&1 in known))
      |> Enum.map(&{:unknown_task, &1})

    %{plan | warnings: plan.warnings ++ unknown}
  end

  # ---------------------------------------------------------------------------
  # helpers

  defp add_prompts(acc, spec, rows, versions) do
    acc
    |> Map.update!(:prompts, &(&1 ++ Enum.map(rows, fn row -> prompt_entry(spec, row) end)))
    |> Map.update!(:prompt_versions, &(&1 ++ versions))
  end

  defp prompt_entry(spec, row) do
    %{
      use_case_key: spec.key,
      name: prompt_name(row.language),
      language: row.language,
      description: prompt_description(spec, row)
    }
  end

  defp prompt_description(%{key: "diary_content_removal"}, row),
    do:
      "Kept identical to diary_generation (system prompt copied from ai_tasks diary_generation/#{row.language || "NULL"} at import, plan.md §12.4)"

  defp prompt_description(_spec, row), do: "HeyDiary " <> task_description(row)

  defp task_description(row), do: "ai_tasks #{row.task_name}/#{row.language || "NULL"}"

  defp commit_message(row),
    do: "import from HeyDiary ai_tasks (#{row.task_name}/#{row.language || "NULL"})"

  @doc "Prompt name: NULL language → `default`, otherwise the language."
  @spec prompt_name(String.t() | nil) :: String.t()
  def prompt_name(nil), do: "default"
  def prompt_name(language), do: language

  # The prompt names that go into the pin — `default` first, then the languages in lexical order.
  defp prompt_names(rows) do
    rows
    |> Enum.map(&prompt_name(&1.language))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1 != "default", &1})
  end

  @doc "Model identifier → name fragment (`google/gemini-3.6-flash` → `google-gemini-3-6-flash`)."
  @spec slug(String.t()) :: String.t()
  def slug(string) do
    string
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
