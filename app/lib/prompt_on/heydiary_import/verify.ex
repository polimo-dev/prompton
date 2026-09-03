defmodule PromptOn.HeyDiaryImport.Verify do
  @moduledoc """
  Migration verification (plan.md §12.2 step 9, ADR 0007 + revision 2026-09-01 "deployments are
  pins"): for every **(task, language)** combination, compares a **reproduction of HeyDiary's
  `Tasks.build_llm_config`** against **`PromptOnSDK.Resolver.resolve` over the committed
  Deployments**. The PromptOn-side input is snapshot v3 (`PromptOn.Deployments.Snapshot`).

  ## One axis fewer — plans are not compared

  With deployments turning from routers into pins, a revision holds **one model**. HeyDiary's
  per-plan model hierarchy (free/pro/max in `plan_ai_models`) cannot be represented, so the import
  collapsed it to the single free (= common) default row (`{:plan_models_flattened, …}` warning),
  and therefore **the plan axis is not compared here either**. The HeyDiary-side expectation is
  computed with `Planner.pinned_plan_model/2` — the very row that became the pin. Plan
  differentiation is now the app's job.

  For the same reason **temperatures are based on the common (NULL-language) row**. A revision
  also has a single `params`, so per-language `ai_tasks.temperature` collapsed
  (`{:language_temperatures_flattened, …}` warning), and the plan report shows that loss.
  Counting it as a mismatch again here would make every normal import fail.

  ## The language axis = the prompt name (routing moved to the app)

  HeyDiary `get_task` was "the language row if there is one, else the NULL row". The PromptOn
  resolver does not fall back (`{:error, :unknown_prompt}`), so **that fallback became the app's
  rule**: the app sends `prompt: "<language>"` when a prompt for that language is deployed, else
  `prompt: "default"`. This module reproduces that rule as is (`app_prompt_name/3`) and checks
  that both sides pick the same document.

  Compared fields: `model`, `temperature`, `providers` (`effective_provider_options["only"]`),
  `allow_fallbacks`, `system_prompt` (the first message content rendered with empty variables —
  this also checks that the escapes come back as the original) / `text_template` for
  `voice_transcription`. When both sides have "no config" (HeyDiary no rows ↔ PromptOn resolution
  failure), that is a match.

  `diary_content_removal` computes the HeyDiary side as the `diary_generation` config + the code
  default 0.3. `diary_embedding` is not a resolve target and is skipped.
  """

  alias PromptOn.HeyDiaryImport.{Dump, Planner, Spec}
  alias PromptOnSDK.{Resolver, SnapshotData, Template}

  @extra_languages ["", "xx"]

  @type mismatch :: %{
          use_case: String.t(),
          language: String.t(),
          prompt: String.t(),
          field: atom(),
          heydiary: term(),
          prompton: term()
        }

  @doc """
  Returns the list of mismatches (an empty list = verification passed). `snapshot` is a
  `%PromptOnSDK.SnapshotData{}` or a snapshot map (the `map` of a
  `PromptOn.Projects.config_snapshot/…` result).
  """
  @spec compare(Dump.t() | map(), SnapshotData.t() | map()) :: [mismatch()]
  def compare(dump, snapshot) do
    {:ok, dump} = Dump.parse(dump)
    snapshot = decode!(snapshot)

    Spec.use_cases()
    |> Enum.reject(&(&1.kind == :embedding))
    |> Enum.flat_map(fn spec ->
      Enum.flat_map(languages(dump, spec.source_task), &compare_case(dump, snapshot, spec, &1))
    end)
  end

  @doc "The list of verified combinations `%{use_case, language, prompt}` (for tests and reports)."
  @spec cases(Dump.t()) :: [map()]
  def cases(dump) do
    Spec.use_cases()
    |> Enum.reject(&(&1.kind == :embedding))
    |> Enum.flat_map(fn spec ->
      for language <- languages(dump, spec.source_task) do
        %{
          use_case: spec.key,
          language: language,
          prompt: app_prompt_name(dump, spec.source_task, language)
        }
      end
    end)
  end

  @doc """
  The prompt name the app must send — the language when an `ai_tasks` row for that language
  exists, else `"default"` (HeyDiary `get_task`'s fallback reproduced on the app side).
  """
  @spec app_prompt_name(Dump.t(), String.t(), String.t() | nil) :: String.t()
  def app_prompt_name(dump, task_name, language) do
    rows = Dump.task_rows(dump, task_name)

    if is_binary(language) and language != "" and Enum.any?(rows, &(&1.language == language)),
      do: language,
      else: Planner.prompt_name(nil)
  end

  # ---------------------------------------------------------------------------

  defp languages(dump, task_name) do
    from_dump = dump |> Dump.languages(task_name) |> Enum.reject(&is_nil/1)
    Enum.uniq(from_dump ++ @extra_languages)
  end

  defp compare_case(dump, snapshot, spec, language) do
    prompt = app_prompt_name(dump, spec.source_task, language)
    expected = heydiary(dump, spec, language)
    actual = prompton(snapshot, spec, prompt)
    base = %{use_case: spec.key, language: language, prompt: prompt}

    case {expected, actual} do
      {nil, nil} ->
        []

      {nil, %{}} ->
        [Map.merge(base, %{field: :resolution, heydiary: :no_rows, prompton: :resolved})]

      {%{}, nil} ->
        [Map.merge(base, %{field: :resolution, heydiary: :resolved, prompton: :unresolved})]

      {%{} = e, %{} = a} ->
        [:model, :temperature, :providers, :allow_fallbacks, :system_prompt]
        |> Enum.reject(&(Map.get(e, &1) == Map.get(a, &1)))
        |> Enum.map(
          &Map.merge(base, %{field: &1, heydiary: Map.get(e, &1), prompton: Map.get(a, &1)})
        )
    end
  end

  # ---------------------------------------------------------------------------
  # HeyDiary side (Tasks.get_task + the pinned plan_ai_models row + build_llm_config)

  defp heydiary(dump, %{key: "voice_transcription"} = spec, language) do
    case Dump.task(dump, spec.source_task, language) do
      nil ->
        nil

      task ->
        %{
          model: Spec.whisper_model().model_id,
          temperature: nil,
          providers: nil,
          allow_fallbacks: nil,
          system_prompt: task.system_prompt
        }
    end
  end

  defp heydiary(dump, spec, language) do
    task = Dump.task(dump, spec.source_task, language)
    plan_model = Planner.pinned_plan_model(dump, spec.source_task)

    if task && plan_model do
      %{
        model: plan_model.model,
        temperature: temperature(dump, spec, plan_model),
        providers: plan_model.providers,
        allow_fallbacks: plan_model.allow_fallbacks,
        system_prompt: task.system_prompt
      }
    end
  end

  # Per-language temperatures collapsed — computed from the common (NULL) row (see the moduledoc).
  defp temperature(dump, spec, plan_model) do
    common = Dump.task(dump, spec.source_task, nil)

    plan_model.temperature || (common && common.temperature) ||
      Spec.code_default_temperature(spec.key)
  end

  # ---------------------------------------------------------------------------
  # PromptOn side (PromptOnSDK.Resolver.resolve)

  defp prompton(snapshot, spec, prompt) do
    case Resolver.resolve(snapshot, spec.key, prompt: prompt) do
      {:ok, resolution} ->
        %{
          model: resolution.model,
          temperature: param(spec, resolution),
          providers: provider_option(spec, resolution, "only"),
          allow_fallbacks: provider_option(spec, resolution, "allow_fallbacks"),
          system_prompt: system_prompt(spec, resolution)
        }

      {:error, _} ->
        nil
    end
  end

  defp param(%{kind: :text}, _resolution), do: nil
  defp param(_spec, resolution), do: Map.get(resolution.effective_params, "temperature")

  defp provider_option(%{kind: :text}, _resolution, _key), do: nil

  defp provider_option(_spec, resolution, key),
    do: Map.get(resolution.effective_provider_options, key)

  defp system_prompt(%{kind: :text}, %{text_template: text, engine: engine}),
    do: render(text, engine)

  defp system_prompt(_spec, %{messages: [%{content: content} | _], engine: engine}),
    do: render(content, engine)

  defp system_prompt(_spec, _resolution), do: nil

  defp render(nil, _engine), do: nil

  defp render(source, engine) do
    case Template.render(source, %{}, engine: engine || :liquid) do
      {:ok, rendered} -> rendered
      {:error, reason} -> {:render_error, reason}
    end
  end

  defp decode!(%SnapshotData{} = snapshot), do: snapshot

  defp decode!(map) when is_map(map) do
    case SnapshotData.decode(map) do
      {:ok, snapshot, _warnings} -> snapshot
      {:error, reason} -> raise ArgumentError, "invalid snapshot: #{inspect(reason)}"
    end
  end
end
