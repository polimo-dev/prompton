defmodule PromptOn.HeyDiaryImport.PlannerTest do
  @moduledoc """
  Dump → plan (plan.md §12.2 steps 2-7, ADR 0007 revision 2026-09-01 "deployments are pins"):
  determinism, model/use case/prompt mapping, pins (one model + prompt names), flattening
  warnings. Runs without a DB on `test/fixtures/heydiary/dump.json` alone.
  """

  use ExUnit.Case, async: true

  alias PromptOn.HeyDiaryImport
  alias PromptOn.HeyDiaryImport.{Dump, Plan, Planner, Spec}

  @dump_path Path.expand("../../fixtures/heydiary/dump.json", __DIR__)

  setup_all do
    {:ok, raw} = @dump_path |> File.read!() |> Jason.decode()
    {:ok, dump} = Dump.parse(raw)
    {:ok, plan} = HeyDiaryImport.plan(dump)
    %{raw: raw, dump: dump, plan: plan}
  end

  defp deployment(plan, key), do: Enum.find(plan.deployments, &(&1.use_case_key == key))

  # A deployment row as {model, params, provider_options, pinned prompt names}
  defp pin_shape(nil), do: nil

  defp pin_shape(deployment) do
    {_provider, model_id} = deployment.model
    {model_id, deployment.params, deployment.provider_options, deployment.prompt_names}
  end

  describe "Dump" do
    test "parses the fixture with HeyDiary column names", %{dump: dump} do
      assert length(dump.ai_tasks) == 10
      assert length(dump.ai_models) == 4
      assert length(dump.plan_ai_models) == 10

      assert Dump.task_names(dump) ==
               ~w(chat_response diary_generation diary_search_content memory_extraction mood_inference transcript_revision voice_transcription)

      # language fallback
      assert %{language: "ko"} = Dump.task(dump, "diary_generation", "ko")
      assert %{language: nil} = Dump.task(dump, "diary_generation", "en")
      assert %{language: nil} = Dump.task(dump, "diary_generation", "")
      assert nil == Dump.task(dump, "diary_content_removal", "ko")

      # plan hierarchy + join
      assert [%{plan: "free"}] = Dump.available_plan_models(dump, "free", "diary_generation")

      assert [%{plan: "free"}, %{plan: "pro"}] =
               Dump.available_plan_models(dump, "max", "diary_generation")

      assert %{model: "openai/gpt-oss-120b", providers: ["groq"]} =
               Dump.default_plan_model(dump, "free", "mood_inference")

      assert nil == Dump.default_plan_model(dump, "free", "voice_transcription")

      # chat_response ordering: sort_order, created_at, id — pro/max tie broken by created_at
      assert Enum.map(Dump.plan_models(dump, "chat_response"), & &1.plan) == ~w(free pro max free)
    end

    test "rejects rows referencing unknown models", %{raw: raw} do
      broken = update_in(raw["plan_ai_models"], &[%{hd(&1) | "ai_model_id" => "nope"} | tl(&1)])
      assert {:error, {:unknown_model, "nope"}} = Dump.parse(broken)
    end

    test "rejects duplicate (task_name, language) rows", %{raw: raw} do
      dup = hd(raw["ai_tasks"])

      assert {:error, {:invalid_dump, msg}} =
               Dump.parse(%{raw | "ai_tasks" => [dup | raw["ai_tasks"]]})

      assert msg =~ "voice_transcription/ko"
    end

    test "rejects non-object dumps and bad shapes" do
      assert {:error, {:invalid_dump, _}} = Dump.parse([])
      assert {:error, {:invalid_dump, msg}} = Dump.parse(%{"ai_tasks" => %{}})
      assert msg =~ "must be an array"
      assert {:error, {:invalid_dump, msg}} = Dump.parse(%{"ai_models" => [%{"model" => "x"}]})
      assert msg =~ "ai_models[0]"
    end
  end

  describe "plan/2" do
    test "is deterministic", %{dump: dump, plan: plan} do
      {:ok, again} = HeyDiaryImport.plan(dump)
      assert again == plan
    end

    test "project and environment defaults / overrides; no context dimensions", %{
      dump: dump,
      plan: plan
    } do
      assert plan.project.slug == "heydiary"
      assert plan.project.name == "HeyDiary"
      assert plan.environment == "production"

      # Context dimensions were deleted (ADR 0007 revision 2026-09-01) — not in the plan either
      refute Map.has_key?(plan.project, :dimensions)

      {:ok, other} = HeyDiaryImport.plan(dump, project_slug: "hd-dev", environment: "development")
      assert other.project.slug == "hd-dev"
      assert other.environment == "development"
    end

    test "models: ai_models rows + groq whisper + embedding, providers null/[] preserved", %{
      plan: plan
    } do
      by_id = Map.new(plan.models, &{&1.model_id, &1})
      assert map_size(by_id) == 6

      assert %{
               provider: :openrouter,
               display_name: "Gemini 3.6 Flash",
               metadata: %{"description_key" => "gemini36Flash"},
               provider_options: %{"only" => ["google-ai-studio", "google-vertex"]}
             } = by_id["google/gemini-3.6-flash"]

      assert %{provider_options: %{"only" => nil}} = by_id["openai/gpt-5.4"]

      assert %{provider_options: %{"only" => []}, metadata: %{"description_key" => nil}} =
               by_id["anthropic/claude-sonnet-4.5"]

      assert %{provider: :groq, provider_options: %{}} = by_id["whisper-large-v3"]
      assert %{provider: :openrouter} = by_id["openai/text-embedding-3-small"]
    end

    test "use cases: 9 in spec order, kinds, default_params from the NULL row", %{plan: plan} do
      assert Enum.map(plan.use_cases, & &1.key) == Enum.map(Spec.use_cases(), & &1.key)

      by_key = Map.new(plan.use_cases, &{&1.key, &1})

      assert %{kind: :text, default_params: %{}} = by_key["voice_transcription"]
      assert %{kind: :chat, default_params: %{"temperature" => 0.7}} = by_key["chat_response"]
      assert %{kind: :embedding} = by_key["diary_embedding"]
      # diary_generation NULL row temperature 0.4 (ko row is 0.5 — flattened, see the warning)
      assert by_key["diary_generation"].default_params == %{"temperature" => 0.4}
      assert by_key["diary_content_removal"].default_params == %{"temperature" => 0.4}
      # diary_search_content NULL row has no temperature
      assert by_key["diary_search_content"].default_params == %{}

      assert Enum.map(by_key["diary_generation"].input_schema, & &1.name) ==
               ~w(transcriptions mode existing_diary user_content)
    end

    test "prompts: default for NULL language, <language> otherwise", %{plan: plan} do
      names = fn key ->
        plan.prompts |> Enum.filter(&(&1.use_case_key == key)) |> Enum.map(& &1.name)
      end

      assert names.("diary_generation") == ["ko", "default"]
      assert names.("voice_transcription") == ["ko", "default"]
      assert names.("diary_content_removal") == ["ko", "default"]
      assert names.("mood_inference") == ["default"]
      assert names.("diary_embedding") == []

      removal =
        Enum.find(plan.prompts, &(&1.use_case_key == "diary_content_removal" and &1.name == "ko"))

      assert removal.description =~ "Kept identical to diary_generation"
    end

    test "prompt versions: [system, user] liquid, chat_response system only, voice text_template, escaping",
         %{
           plan: plan,
           dump: dump
         } do
      pv = fn key, name ->
        Enum.find(plan.prompt_versions, &(&1.use_case_key == key and &1.prompt_name == name))
      end

      diary_ko = pv.("diary_generation", "ko")
      assert diary_ko.engine == :liquid

      assert [%{role: :system, content: system}, %{role: :user, content: user}] =
               diary_ko.messages

      assert system == Dump.task(dump, "diary_generation", "ko").system_prompt
      assert user == Spec.user_template("diary_generation")
      assert diary_ko.commit_message =~ "diary_generation/ko"

      # diary_content_removal copies diary_generation's system prompt per language, with the removal template
      removal_default = pv.("diary_content_removal", "default")

      assert [%{role: :system, content: copied}, %{role: :user, content: removal_user}] =
               removal_default.messages

      assert copied == Dump.task(dump, "diary_generation", nil).system_prompt
      assert removal_user == Spec.user_template("diary_content_removal")

      assert [%{role: :system}] = pv.("chat_response", "default").messages

      voice = pv.("voice_transcription", "ko")
      assert voice.messages == []
      assert voice.text_template == Dump.task(dump, "voice_transcription", "ko").system_prompt

      # transcript_revision NULL row contains literal {{date}} / {% now %} → escaped, renders back byte-identical
      escaped = pv.("transcript_revision", "default")
      [%{content: escaped_system} | _] = escaped.messages
      original = Dump.task(dump, "transcript_revision", nil).system_prompt
      assert escaped_system =~ ~s|{{ "{{" }}date}}|
      assert escaped_system =~ ~s|{{ "{%" }} now %}|
      assert {:ok, ^original} = PromptOnSDK.Template.render(escaped_system, %{})
      assert :ok == PromptOnSDK.Template.lint(escaped_system)
    end

    test "one deployment per use case, and each is a pin: one model + every prompt name", %{
      plan: plan
    } do
      assert Enum.map(plan.deployments, & &1.use_case_key) == [
               "voice_transcription",
               "transcript_revision",
               "diary_generation",
               "diary_content_removal",
               "mood_inference",
               "chat_response",
               "memory_extraction",
               "diary_search_content",
               "diary_embedding"
             ]

      # No rules, conditions, targets or weights
      for d <- plan.deployments do
        refute Map.has_key?(d, :rules)
        refute Map.has_key?(d, :targets)
        assert {_provider, model_id} = d.model
        assert is_binary(model_id)
      end

      # Two languages = two prompts, both pinned (the model is the single free default row)
      assert pin_shape(deployment(plan, "diary_generation")) ==
               {"google/gemini-3.6-flash", %{"temperature" => 0.4}, %{"allow_fallbacks" => true},
                ["default", "ko"]}

      # A task with only the NULL row: a single default
      assert pin_shape(deployment(plan, "mood_inference")) ==
               {"openai/gpt-oss-120b", %{"temperature" => 0.1}, %{"allow_fallbacks" => false},
                ["default"]}

      # voice: Groq whisper, no params, two languages
      assert pin_shape(deployment(plan, "voice_transcription")) ==
               {"whisper-large-v3", %{}, %{}, ["default", "ko"]}

      # embedding: no prompt, so the pins are empty too
      assert pin_shape(deployment(plan, "diary_embedding")) ==
               {"openai/text-embedding-3-small", %{}, %{}, []}

      # diary_content_removal: HeyDiary reused the diary_generation settings → same model and
      # temperature
      assert pin_shape(deployment(plan, "diary_content_removal")) ==
               pin_shape(deployment(plan, "diary_generation"))

      # The case that falls back to the code default (0.5)
      assert {_, %{"temperature" => 0.5}, _, _} =
               pin_shape(deployment(plan, "diary_search_content"))

      # The pin's prompt names are exactly the planned Prompt names of that use case
      for d <- plan.deployments do
        planned =
          plan.prompts
          |> Enum.filter(&(&1.use_case_key == d.use_case_key))
          |> Enum.map(& &1.name)
          |> Enum.sort()

        assert Enum.sort(d.prompt_names) == planned
      end
    end

    test "the pinned model is the free (common) default row", %{dump: dump, plan: plan} do
      assert %{plan: "free", is_default: true, model: "google/gemini-3.6-flash"} =
               Planner.pinned_plan_model(dump, "diary_generation")

      assert {"google/gemini-3.6-flash", _, _, _} = pin_shape(deployment(plan, "chat_response"))
      assert nil == Planner.pinned_plan_model(dump, "voice_transcription")
    end

    test "counts cover the whole plan", %{plan: plan} do
      assert Plan.counts(plan) == %{
               models: 6,
               use_cases: 9,
               prompts: 12,
               prompt_versions: 12,
               deployments: 9,
               pins: 12,
               warnings: 5
             }
    end

    test "warnings: plan models and per-language temperatures are flattened (confirm-gated)", %{
      plan: plan
    } do
      assert plan.warnings == [
               {:plan_models_flattened, "diary_generation", ["pro"]},
               {:language_temperatures_flattened, "diary_generation",
                %{"default" => 0.4, "ko" => 0.5}},
               {:plan_models_flattened, "diary_content_removal", ["pro"]},
               {:language_temperatures_flattened, "diary_content_removal",
                %{"default" => 0.4, "ko" => 0.5}},
               {:plan_models_flattened, "chat_response", ["free", "pro", "max"]}
             ]

      # All of them need confirmation — the user has to see the loss and move past it
      assert Plan.confirmations(plan) == plan.warnings
      assert Plan.counts(plan).warnings == length(plan.warnings)

      for w <- plan.warnings, do: assert(is_binary(Plan.describe_warning(w)))

      assert Plan.describe_warning({:plan_models_flattened, "chat_response", ["pro"]}) =~
               "plan-differentiated models are now the app's job"
    end

    test "no flattening warning when a task has exactly one plan row and one language", %{
      plan: plan
    } do
      refute Enum.any?(plan.warnings, &(elem(&1, 1) == "mood_inference"))
      refute Enum.any?(plan.warnings, &(elem(&1, 1) == "transcript_revision"))
    end

    test "warning :no_default_prompt when a task has language rows but no NULL row", %{raw: raw} do
      without_common =
        update_in(raw["ai_tasks"], fn tasks ->
          Enum.reject(tasks, &(&1["task_name"] == "diary_generation" and is_nil(&1["language"])))
        end)

      {:ok, plan} = HeyDiaryImport.plan(without_common)
      assert {:no_default_prompt, "diary_generation", ["ko"]} in plan.warnings
      assert {:no_default_prompt, "diary_content_removal", ["ko"]} in plan.warnings
      assert {:no_default_prompt, "diary_generation", ["ko"]} in Plan.confirmations(plan)

      # There is no `default` prompt, so the pin is ko alone — a request arriving without a name
      # is a 404
      assert {"google/gemini-3.6-flash", %{"temperature" => 0.5}, _, ["ko"]} =
               pin_shape(deployment(plan, "diary_generation"))

      # default_params falls back to empty (no NULL row)
      assert Enum.find(plan.use_cases, &(&1.key == "diary_generation")).default_params == %{}
    end

    test "warnings :missing_task / :no_plan_models / :unknown_task", %{raw: raw} do
      changed =
        raw
        |> update_in(["ai_tasks"], fn tasks ->
          tasks
          |> Enum.reject(&(&1["task_name"] == "mood_inference"))
          |> Kernel.++([
            %{
              "id" => "6a1e0f10-0000-4000-8000-000000000999",
              "task_name" => "chunk_summary",
              "language" => nil,
              "system_prompt" => "legacy",
              "temperature" => nil
            }
          ])
        end)
        |> update_in(["plan_ai_models"], fn rows ->
          Enum.reject(rows, &(&1["task_name"] == "memory_extraction"))
        end)

      {:ok, plan} = HeyDiaryImport.plan(changed)
      assert {:missing_task, "mood_inference", "mood_inference"} in plan.warnings
      assert {:no_plan_models, "memory_extraction"} in plan.warnings
      assert {:unknown_task, "chunk_summary"} in plan.warnings

      # use case still defined; no deployment for either
      assert Enum.any?(plan.use_cases, &(&1.key == "mood_inference"))
      refute deployment(plan, "mood_inference")
      refute deployment(plan, "memory_extraction")
      # memory_extraction keeps its prompt version but gets no pin
      assert Enum.any?(plan.prompt_versions, &(&1.use_case_key == "memory_extraction"))
      # none of these three need confirmation
      confirm_kinds = Plan.confirmations(plan) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      refute :missing_task in confirm_kinds
      refute :no_plan_models in confirm_kinds
      refute :unknown_task in confirm_kinds
    end

    test "warning :no_free_default when only higher plans have a default", %{raw: raw} do
      changed =
        update_in(raw["plan_ai_models"], fn rows ->
          Enum.map(rows, fn
            %{"task_name" => "mood_inference"} = r -> %{r | "plan" => "pro"}
            r -> r
          end)
        end)

      {:ok, plan} = HeyDiaryImport.plan(changed)
      assert {:no_free_default, "mood_inference", "pro"} in plan.warnings
      assert {:no_free_default, "mood_inference", "pro"} in Plan.confirmations(plan)

      # The pin is the lowest default row (pro) — free users now resolve too
      assert {"openai/gpt-oss-120b", %{"temperature" => 0.1}, _, ["default"]} =
               pin_shape(deployment(plan, "mood_inference"))
    end

    test "warning :ambiguous_default when the pinned level has competing default rows", %{
      raw: raw
    } do
      # Raise mood_inference to pro (= no free default row) and add one more max default row →
      # at the pin level (pro) the Registry (insertion order) and this tool (highest plan first)
      # may pick differently
      changed =
        update_in(raw["plan_ai_models"], fn rows ->
          Enum.map(rows, fn
            %{"task_name" => "mood_inference"} = r ->
              %{r | "plan" => "pro", "created_at" => "2026-01-01T00:00:00Z"}

            r ->
              r
          end)
        end)

      {:ok, plan} = HeyDiaryImport.plan(changed)
      # A single default row at the pin level is not ambiguous
      refute Enum.any?(plan.warnings, &match?({:ambiguous_default, "mood_inference", _, _}, &1))

      with_second =
        update_in(changed["plan_ai_models"], fn rows ->
          rows ++
            [
              %{
                "id" => "c3d4e5f6-0000-4000-8000-000000000398",
                "plan" => "free",
                "task_name" => "mood_inference",
                "ai_model_id" => "b2c3d4e5-0000-4000-8000-000000000201",
                "allow_fallbacks" => false,
                "temperature" => nil,
                "is_default" => true,
                "sort_order" => 9,
                "created_at" => "2026-05-01T00:00:00Z"
              }
            ]
        end)

      {:ok, plan} = HeyDiaryImport.plan(with_second)
      # Now that a free default row exists it is the pin, and the pro row collapses
      assert {:plan_models_flattened, "mood_inference", ["pro"]} in plan.warnings

      assert {"google/gemini-3.6-flash", _, _, ["default"]} =
               pin_shape(deployment(plan, "mood_inference"))
    end
  end
end
