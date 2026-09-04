defmodule PromptOn.HeyDiaryImport.Export do
  @moduledoc """
  Reverse direction (for rollback): PromptOn **schema-v4 use-case document**
  (live Deployment = pin) → HeyDiary
  `ai_models` / `ai_tasks` / `plan_ai_models` UPSERT SQL (plan.md §12.2 last paragraph, ADR 0007
  revision 2026-09-01). Brings the tables up to date when, during the parallel-run period, edits
  happened only in PromptOn and you roll back to the HeyDiary DB path.

  ## The round trip is **asymmetric (lossy)**

  Now that deployments are pins, a revision holds exactly **one** model. HeyDiary's
  `plan_ai_models` splits models by (plan × task) and even carries user-selectable lists, and that
  axis no longer exists on the PromptOn side. Therefore:

  - **Every plan receives the same model, temperature and allow_fallbacks** (the
    `free`/`pro`/`max` rows become identical). The loss that the import warned about with
    `{:plan_models_flattened, …}` shows up here as is.
  - **Non-default (user-selectable) rows are not produced.** Existing rows are never removed (no
    deletes), so the choices that were left on the HeyDiary side stay there — only the
    `is_default` rows are refreshed by this SQL.
  - **`plan_ai_models.id` is not preserved.** A pin has no place to carry that id
    (the UPDATE + INSERT go by `(task_name, plan, is_default)`).

  If per-plan model differentiation is needed again, that is **the app's choice** (splitting use
  cases or prompts) or a future feature. The same warning is stamped as a comment at the top of
  the generated SQL.

  ## Mapping

  - `ai_models` — the `openrouter` models pinned by the live Deployments of the migrated UseCases.
    Upserted via the `model` UNIQUE. (`plan_ai_models.ai_model_id` is joined with a
    `(SELECT id FROM ai_models WHERE model = …)` subquery.)
  - `ai_tasks` — the pin's prompt names → `(task, language)` rows (`default` → `language NULL`,
    any other name as is). The system prompt is the first message of the pinned PromptVersion
    (`text_template` for `voice_transcription`) rendered with empty variables (escapes restored).
    `temperature` is the revision's effective temperature (else `UseCase.default_params`). Because
    UNIQUE(task_name, language) does not distinguish NULLs, the upsert is
    `UPDATE … WHERE language IS NOT DISTINCT FROM` + `INSERT … WHERE NOT EXISTS`.
  - `plan_ai_models` — one `is_default = true` row per plan (`Dump.plans/0`). As noted above, all
    of them carry the same model. `voice_transcription` (Groq) has no rows in HeyDiary either and
    is not exported.
  - `diary_content_removal` (no rows in HeyDiary) and `diary_embedding` are not exported.

  Nothing is deleted (existing rows remain). The result is a psql script wrapped in
  `BEGIN; … COMMIT;`.
  """

  alias PromptOn.HeyDiaryImport.{Dump, Spec}
  alias PromptOnSDK.{Params, Template, UseCaseDocument}

  @lossy_warning [
    "-- WARNING: this export is LOSSY.",
    "-- A PromptOn deployment revision pins exactly ONE model, so every plan below gets the same",
    "-- model/temperature/allow_fallbacks, no user-selectable (is_default = false) rows are produced,",
    "-- and the original plan_ai_models.id values are not preserved. Plan-differentiated models are",
    "-- the app's job now (see docs/adr/0007 — \"deployments are pins\")."
  ]

  @doc "Use-case document (`%UseCaseDocument{}` or map) → SQL string."
  @spec sql(UseCaseDocument.t() | map()) :: String.t()
  def sql(snapshot) do
    snapshot = decode!(snapshot)
    specs = exportable_specs()

    statements =
      @lossy_warning ++
        ["", "BEGIN;", ""] ++
        section("ai_models", ai_models_sql(snapshot, specs)) ++
        section("ai_tasks", ai_tasks_sql(snapshot, specs)) ++
        section("plan_ai_models", plan_ai_models_sql(snapshot, specs)) ++
        ["COMMIT;"]

    Enum.join(statements, "\n") <> "\n"
  end

  defp exportable_specs do
    Spec.use_cases()
    |> Enum.reject(&(&1.kind == :embedding or &1.key == "diary_content_removal"))
  end

  defp section(name, []), do: ["-- #{name}: nothing to export", ""]
  defp section(name, statements), do: ["-- #{name}"] ++ statements ++ [""]

  # ---------------------------------------------------------------------------
  # ai_models

  defp ai_models_sql(snapshot, specs) do
    specs
    |> Enum.flat_map(&List.wrap(pinned_model(snapshot, &1.key)))
    |> Enum.uniq_by(& &1.model_id)
    |> Enum.filter(&(&1.provider == :openrouter))
    |> Enum.sort_by(& &1.model_id)
    |> Enum.map(fn model ->
      metadata = Params.stringify_keys(model.metadata)
      providers = model.provider_options |> Params.stringify_keys() |> Map.get("only")

      "INSERT INTO ai_models (id, model, display_name, description_key, providers) VALUES " <>
        "(gen_random_uuid(), #{str(model.model_id)}, #{str(model.display_name)}, " <>
        "#{str(metadata["description_key"])}, #{jsonb(providers)})\n" <>
        "  ON CONFLICT (model) DO UPDATE SET display_name = EXCLUDED.display_name, " <>
        "description_key = EXCLUDED.description_key, providers = EXCLUDED.providers, updated_at = CURRENT_TIMESTAMP;"
    end)
  end

  defp deployment(snapshot, key), do: UseCaseDocument.deployment(snapshot, key)

  defp pinned_model(snapshot, key) do
    with %{model_id: model_id} when is_binary(model_id) <- deployment(snapshot, key),
         %{} = model <- Map.get(snapshot.models, model_id) do
      model
    else
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # ai_tasks

  defp ai_tasks_sql(snapshot, specs) do
    Enum.flat_map(specs, fn spec ->
      case deployment(snapshot, spec.key) do
        %{prompt_pins: pins} when pins != %{} -> ai_task_rows(snapshot, spec, pins)
        _ -> []
      end
    end)
  end

  defp ai_task_rows(snapshot, spec, pins) do
    temperature = effective_temperature(snapshot, spec)

    for {name, version_id} <- Enum.sort_by(pins, fn {name, _} -> {name != "default", name} end),
        prompt = system_prompt(snapshot, spec, version_id),
        not is_nil(prompt) do
      ai_task_upsert(spec.source_task, language_of(name), prompt, temperature)
    end
  end

  defp language_of("default"), do: nil
  defp language_of(name), do: name

  defp effective_temperature(_snapshot, %{kind: :text}), do: nil

  defp effective_temperature(snapshot, spec) do
    case effective(snapshot, spec.key) do
      %{temperature: t} -> t
      nil -> nil
    end
  end

  defp ai_task_upsert(task_name, language, prompt, temperature) do
    where = "task_name = #{str(task_name)} AND language IS NOT DISTINCT FROM #{str(language)}"

    "UPDATE ai_tasks SET system_prompt = #{str(prompt)}, temperature = #{num(temperature)}, " <>
      "updated_at = CURRENT_TIMESTAMP WHERE #{where};\n" <>
      "INSERT INTO ai_tasks (id, task_name, language, system_prompt, temperature) " <>
      "SELECT gen_random_uuid(), #{str(task_name)}, #{str(language)}, #{str(prompt)}, #{num(temperature)} " <>
      "WHERE NOT EXISTS (SELECT 1 FROM ai_tasks WHERE #{where});"
  end

  defp system_prompt(snapshot, spec, version_id) do
    case Map.get(snapshot.prompt_versions, version_id) do
      nil -> nil
      version -> render(template_source(spec.kind, version), version.engine)
    end
  end

  defp template_source(:text, %{text_template: text}), do: text
  defp template_source(_kind, %{messages: [%{content: content} | _]}), do: content
  defp template_source(_kind, _version), do: nil

  # Turns escapes (`{{ "{{" }}`) back into the original text — when rendering fails, the raw
  # template is used as is.
  defp render(nil, _engine), do: nil

  defp render(source, engine) do
    case Template.render(source, %{}, engine: engine || :liquid) do
      {:ok, rendered} -> rendered
      _ -> source
    end
  end

  # ---------------------------------------------------------------------------
  # plan_ai_models — the same single row for every plan (a pin has no plan axis)

  defp plan_ai_models_sql(snapshot, specs) do
    Enum.flat_map(specs, fn spec ->
      case {spec.kind, effective(snapshot, spec.key)} do
        # voice_transcription (Groq) has no plan_ai_models rows in HeyDiary either
        {:text, _} -> []
        {_, nil} -> []
        {_, eff} -> Enum.map(Dump.plans(), &plan_model_upsert(spec.source_task, &1, eff))
      end
    end)
  end

  defp plan_model_upsert(task_name, plan, eff) do
    where = "task_name = #{str(task_name)} AND plan = #{str(plan)} AND is_default = true"

    "UPDATE plan_ai_models SET ai_model_id = #{model_subselect(eff.model)}, allow_fallbacks = #{bool(eff.allow_fallbacks)}, " <>
      "temperature = #{num(eff.temperature)}, sort_order = 0, updated_at = CURRENT_TIMESTAMP WHERE #{where};\n" <>
      "INSERT INTO plan_ai_models (id, plan, task_name, ai_model_id, allow_fallbacks, temperature, is_default, sort_order) " <>
      "SELECT gen_random_uuid(), #{str(plan)}, #{str(task_name)}, #{model_subselect(eff.model)}, #{bool(eff.allow_fallbacks)}, " <>
      "#{num(eff.temperature)}, true, 0 WHERE NOT EXISTS (SELECT 1 FROM plan_ai_models WHERE #{where});"
  end

  # The revision's effective config = UseCase.default_params ⊕ Deployment.params,
  # Model.provider_options ⊕ the revision's options.
  defp effective(snapshot, key) do
    with %{} = deployment <- deployment(snapshot, key),
         %{} = use_case <- Map.get(snapshot.use_cases, key),
         %{} = model <- Map.get(snapshot.models, deployment.model_id) do
      params = Params.merge(use_case.default_params, deployment.params)
      provider_options = Params.merge(model.provider_options, deployment.provider_options)

      %{
        model: model.model_id,
        temperature: Map.get(params, "temperature"),
        allow_fallbacks: Map.get(provider_options, "allow_fallbacks") == true
      }
    else
      _ -> nil
    end
  end

  defp model_subselect(model), do: "(SELECT id FROM ai_models WHERE model = #{str(model)})"

  # ---------------------------------------------------------------------------
  # SQL literals

  defp str(nil), do: "NULL"
  defp str(value) when is_binary(value), do: "'" <> String.replace(value, "'", "''") <> "'"
  defp str(value), do: str(to_string(value))

  defp num(nil), do: "NULL"
  defp num(value) when is_float(value), do: Float.to_string(value)
  defp num(value) when is_integer(value), do: Integer.to_string(value)
  defp num(value), do: str(to_string(value))

  defp bool(true), do: "true"
  defp bool(_), do: "false"

  defp jsonb(nil), do: "NULL"
  defp jsonb(value), do: str(Jason.encode!(value)) <> "::jsonb"

  defp decode!(%UseCaseDocument{} = snapshot), do: snapshot

  defp decode!(map) when is_map(map) do
    case UseCaseDocument.decode(map) do
      {:ok, snapshot, _warnings} -> snapshot
      {:error, reason} -> raise ArgumentError, "invalid snapshot: #{inspect(reason)}"
    end
  end
end
