defmodule PromptOn.HeyDiaryImport.Planner do
  @moduledoc """
  Dump (`PromptOn.HeyDiaryImport.Dump`) → migration plan (`PromptOn.HeyDiaryImport.Plan`). Pure
  functions, no DB, deterministic (the same dump and options give the same plan).

  Computes plan.md §12.2 steps 2-7 under the ADR 0007 (+ revision 2026-09-01 "deployments are
  pins") model:

  - **Model**: `ai_models` row → `provider :openrouter`, `model_id = model`,
    `metadata %{description_key}`, `provider_options %{"only" => providers}` (`providers` NULL →
    `%{"only" => nil}`, `[]` → `%{"only" => []}` — the contract under which HeyDiary sent
    `provider.only: null`/`[]` as is).
  - **UseCase**: the 7 chat use cases of `Spec.use_cases/0`. `default_params.temperature` = the temperature of
    the source task's common (NULL-language) row (when present).
  - **Prompt/PromptVersion**: one Prompt named `default` per UseCase with one committed version.
    The system message is a Liquid template that branches on optional `language` and renders each
    imported HeyDiary `ai_tasks` row byte-identically; the user message is the §12.3 Liquid
    template. `chat_response` is system only. `diary_content_removal` copies the
    `diary_generation` rows + the removal template.
  - **Deployment**: **one** per use case (`use_case × production`), and it is **one pin**:
    - model = the model of the **free (= common) default row** of `plan_ai_models`
      (`pinned_plan_model/2`). The per-plan model hierarchy cannot be represented because a
      revision holds one model — the other rows are dropped and `{:plan_models_flattened, …}`
      reports it (plan differentiation is the app's job).
    - `params.temperature = coalesce(pm.temperature, ai_tasks common-row temperature, code
      default)`, `provider_options %{"allow_fallbacks" => pm.allow_fallbacks}`.
    - `prompt_names` = `["default"]`. Language is a template variable, not a prompt selector.

  See the `PromptOn.HeyDiaryImport.Plan` moduledoc for the list of warnings.
  """

  alias PromptOn.HeyDiaryImport.{Dump, Plan, Spec}

  @default_project_slug "heydiary"
  @default_environment "production"
  @ignored_heydiary_tasks ~w(voice_transcription)

  @doc """
  Builds the plan. `opts`: `:project_slug` (default `"heydiary"`), `:project_description`
  (default `nil`), `:environment` (default `"production"`).
  """
  @spec plan(Dump.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(%Dump{} = dump, opts \\ []) do
    project = %{
      slug: Keyword.get(opts, :project_slug, @default_project_slug),
      description: Keyword.get(opts, :project_description)
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

    Enum.uniq_by(from_dump, &{&1.provider, &1.model_id})
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

    plan_chat(dump, spec, acc)
  end

  defp default_params(_dump, %{source_task: nil}), do: %{}

  defp default_params(dump, %{source_task: task}) do
    case Dump.task(dump, task, nil) do
      %{temperature: t} when is_float(t) -> %{"temperature" => t}
      _ -> %{}
    end
  end

  # transcript_revision / diary_generation / diary_content_removal / mood_inference /
  # chat_response / memory_extraction / diary_search_content
  defp plan_chat(dump, spec, acc) do
    rows = Dump.task_rows(dump, spec.source_task)
    plan_models = Dump.plan_models(dump, spec.source_task)

    if rows == [] do
      {:ok, warn(acc, {:missing_task, spec.key, spec.source_task})}
    else
      with {:ok, version} <- chat_version(spec, rows) do
        acc =
          acc
          |> add_prompt(spec, rows, version)
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
            prompt_names: [prompt_name(nil)],
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

  defp chat_version(spec, rows) do
    user_template = Spec.user_template(spec.key)

    with {:ok, system} <- system_template(rows) do
      messages =
        [%{role: :system, content: system}] ++
          if(is_nil(user_template), do: [], else: [%{role: :user, content: user_template}])

      {:ok,
       %{
         use_case_key: spec.key,
         prompt_name: prompt_name(nil),
         engine: :liquid,
         messages: messages,
         text_template: nil,
         commit_message: commit_message(rows)
       }}
    end
  end

  defp system_template(rows) do
    rows = Enum.sort_by(rows, &{is_nil(&1.language), &1.language || ""})
    default = Enum.find(rows, &is_nil(&1.language))
    language_rows = Enum.reject(rows, &is_nil(&1.language))

    with {:ok, escaped} <- escaped_rows(rows) do
      template =
        case language_rows do
          [] ->
            Map.fetch!(escaped, default.id)

          [_ | _] ->
            language_branches(language_rows, escaped) <>
              "{% else %}" <> default_system(default, escaped) <> "{% endif %}"
        end

      case PromptOnSDK.Template.lint(template) do
        :ok -> {:ok, template}
        {:error, reason} -> {:error, {:unlintable_system_template, reason}}
      end
    end
  end

  defp escaped_rows(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case Spec.escape_literal(row.system_prompt) do
        {:ok, system} ->
          {:cont, {:ok, Map.put(acc, row.id, system)}}

        {:error, reason} ->
          {:halt, {:error, {:unescapable_system_prompt, row.task_name, row.language, reason}}}
      end
    end)
  end

  defp language_branches(rows, escaped) do
    rows
    |> Enum.with_index()
    |> Enum.map_join(fn {row, index} ->
      tag = if index == 0, do: "if", else: "elsif"
      "{% #{tag} language == #{liquid_string(row.language)} %}" <> Map.fetch!(escaped, row.id)
    end)
  end

  defp default_system(nil, _escaped), do: ""
  defp default_system(row, escaped), do: Map.fetch!(escaped, row.id)

  defp liquid_string(value) do
    ~s("#{value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}")
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
      |> Enum.reject(&(&1 in known or &1 in @ignored_heydiary_tasks))
      |> Enum.map(&{:unknown_task, &1})

    %{plan | warnings: plan.warnings ++ unknown}
  end

  # ---------------------------------------------------------------------------
  # helpers

  defp add_prompt(acc, spec, rows, version) do
    acc
    |> Map.update!(:prompts, &(&1 ++ [prompt_entry(spec, rows)]))
    |> Map.update!(:prompt_versions, &(&1 ++ [version]))
  end

  defp prompt_entry(spec, rows) do
    %{
      use_case_key: spec.key,
      name: prompt_name(nil),
      language: nil,
      description: prompt_description(spec, rows)
    }
  end

  defp prompt_description(%{key: "diary_content_removal"}, rows),
    do:
      "Single default prompt; system branches by language and copies diary_generation ai_tasks rows " <>
        languages_description(rows) <> " at import (plan.md §12.4)"

  defp prompt_description(_spec, rows),
    do:
      "Single default prompt; system branches by language from HeyDiary " <>
        rows_description(rows)

  defp rows_description(rows), do: Enum.map_join(rows, ", ", &task_description/1)

  defp languages_description(rows),
    do: Enum.map_join(rows, ", ", &(&1.language || "NULL"))

  defp task_description(row), do: "ai_tasks #{row.task_name}/#{row.language || "NULL"}"

  defp commit_message(rows), do: "import from HeyDiary " <> rows_description(rows)

  @doc "The single Prompt name used by HeyDiary imports."
  @spec prompt_name(String.t() | nil) :: String.t()
  def prompt_name(_language), do: "default"

  @doc "Model identifier → name fragment (`google/gemini-3.6-flash` → `google-gemini-3-6-flash`)."
  @spec slug(String.t()) :: String.t()
  def slug(string) do
    string
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
