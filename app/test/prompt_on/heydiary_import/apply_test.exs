defmodule PromptOn.HeyDiaryImport.ApplyTest do
  @moduledoc """
  A real import from the fixture dump (plan.md §12.2 steps 2-7, ADR 0007 revision 2026-09-01
  "deployments are pins") → snapshot v3 → `Verify.compare` (step 9) → `Export.sql` round trip.
  """

  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Deployments
  alias PromptOn.HeyDiaryImport
  alias PromptOn.HeyDiaryImport.{Dump, Export, Verify}
  alias PromptOn.{Projects, Prompts}
  alias PromptOnSDK.{Resolver, SnapshotData}

  @dump_path Path.expand("../../fixtures/heydiary/dump.json", __DIR__)

  setup do
    {:ok, dump} = Dump.load_file(@dump_path)
    {:ok, plan} = HeyDiaryImport.plan(dump)
    user = user_fixture()
    org = organization_for(user)
    %{dump: dump, plan: plan, org: org, user: user, actor: system_actor()}
  end

  defp import!(plan, org, actor, opts \\ []) do
    {:ok, summary} =
      HeyDiaryImport.apply(plan, [actor: actor, organization_id: org.id] ++ opts)

    summary
  end

  defp snapshot!(summary, actor) do
    {:ok, %{map: map}} =
      Projects.config_snapshot(summary.environment_id,
        actor: actor,
        tenant: summary.project_id
      )

    {:ok, snapshot, []} = SnapshotData.decode(map)
    {map, snapshot}
  end

  describe "apply/2" do
    test "creates project/env/models/use cases/prompts/versions/pinned deployments in one go", %{
      plan: plan,
      org: org,
      actor: actor
    } do
      summary = import!(plan, org, actor)

      assert summary.project_slug == "heydiary"
      assert summary.environment == "production"
      refute summary.reused_project?

      assert summary.counts == %{
               models: 6,
               use_cases: 9,
               prompts: 12,
               prompt_versions: 12,
               deployments: 9,
               pins: 12
             }

      # Flattening warnings are carried in the summary as is (the very list the mix task asked to
      # confirm)
      assert {:plan_models_flattened, "chat_response", ["free", "pro", "max"]} in summary.warnings

      scope = [actor: actor, tenant: summary.project_id]

      {:ok, project} = Projects.get_project(summary.project_id, actor: actor)
      # Context dimensions were deleted from the resource
      refute Map.has_key?(project, :dimensions)

      # Every use case has exactly one live Deployment (revision 1), and each pins one model
      {:ok, use_cases} = Prompts.list_use_cases(scope)
      assert length(use_cases) == 9

      for use_case <- use_cases do
        {:ok, deployment} =
          Deployments.current_deployment(use_case.id, summary.environment_id, scope)

        assert deployment, "no live deployment for #{use_case.key}"
        assert deployment.revision == 1
        assert is_binary(deployment.model_id)

        {:ok, prompts} = Prompts.list_prompts(use_case.id, scope)

        assert deployment.prompt_pins |> Map.keys() |> Enum.sort() ==
                 prompts |> Enum.map(& &1.name) |> Enum.sort(),
               "#{use_case.key} does not pin every prompt"
      end

      # A use case with two language rows has two Prompts, each at v1 (a committed immutable
      # version)
      {:ok, diary} = Prompts.get_use_case_by_key("diary_generation", scope)
      {:ok, prompts} = Prompts.list_prompts(diary.id, scope)
      assert prompts |> Enum.map(& &1.name) |> Enum.sort() == ["default", "ko"]

      for prompt <- prompts do
        {:ok, [version]} = Prompts.list_prompt_versions(prompt.id, scope)
        assert version.number == 1
        assert version.engine == :liquid
      end

      # The pin holds one model + temperature/allow_fallbacks inline in the revision
      {:ok, deployment} = Deployments.current_deployment(diary.id, summary.environment_id, scope)
      assert deployment.params == %{"temperature" => 0.4}
      assert deployment.provider_options == %{"allow_fallbacks" => true}
      assert map_size(deployment.prompt_pins) == 2
    end

    test "refuses to import twice into a non-empty project unless forced, then reuses", %{
      plan: plan,
      org: org,
      actor: actor
    } do
      first = import!(plan, org, actor)

      assert {:error, {:project_not_empty, "heydiary"}} =
               HeyDiaryImport.apply(plan, actor: actor, organization_id: org.id)

      second = import!(plan, org, actor, force: true)
      assert second.project_id == first.project_id
      assert second.reused_project?

      scope = [actor: actor, tenant: second.project_id]
      {:ok, diary} = Prompts.get_use_case_by_key("diary_generation", scope)
      {:ok, [prompt | _]} = Prompts.list_prompts(diary.id, scope)
      {:ok, versions} = Prompts.list_prompt_versions(prompt.id, scope)
      assert Enum.map(versions, & &1.number) == [2, 1]

      {:ok, history} = Deployments.deployment_history(diary.id, second.environment_id, scope)
      assert Enum.map(history, & &1.revision) == [2, 1]

      # Live is revision 2, and its pins point only at the versions the second import committed
      # (number 2)
      {:ok, live} = Deployments.current_deployment(diary.id, second.environment_id, scope)
      assert live.revision == 2
      {:ok, all_prompts} = Prompts.list_prompts(diary.id, scope)

      latest_ids =
        for p <- all_prompts,
            {:ok, vs} = Prompts.list_prompt_versions(p.id, scope),
            v <- vs,
            v.number == 2,
            do: v.id

      assert live.prompt_pins |> Map.values() |> Enum.sort() == Enum.sort(latest_ids)

      assert second.counts.models == 6
      assert second.counts.use_cases == 9
    end

    test "rolls back everything when a step fails", %{plan: plan, org: org, actor: actor} do
      # A deployment pinning a model that is not in the plan → commit_deployments raises KeyError →
      # the transaction rolls back
      [deployment | _] = plan.deployments
      broken_deployment = %{deployment | model: {:openrouter, "missing/model"}}
      broken = %{plan | deployments: [broken_deployment]}

      assert_raise KeyError, fn ->
        HeyDiaryImport.apply(broken, actor: actor, organization_id: org.id)
      end

      assert {:ok, nil} = Projects.get_project_by_slug(org.id, "heydiary", actor: actor)
    end

    test "creates the target environment when it does not exist", %{
      dump: dump,
      org: org,
      actor: actor
    } do
      {:ok, plan} = HeyDiaryImport.plan(dump, environment: "development")
      summary = import!(plan, org, actor)
      assert summary.environment == "development"

      {:ok, env} =
        Projects.get_environment_by_slug("development", actor: actor, tenant: summary.project_id)

      assert env.id == summary.environment_id
    end
  end

  describe "snapshot after import" do
    test "resolves by prompt name and Verify.compare reports no mismatches", %{
      dump: dump,
      plan: plan,
      org: org,
      actor: actor
    } do
      summary = import!(plan, org, actor)
      {map, snapshot} = snapshot!(summary, actor)

      assert map["schema_version"] == 3
      assert map["project"] == "heydiary"
      assert map["environment"] == "production"
      assert map |> Map.fetch!("use_cases") |> map_size() == 9
      assert map |> Map.fetch!("deployments") |> map_size() == 9
      refute Map.has_key?(map, "dimensions")

      # Language branching = the prompt name. Model and params are one regardless of the name.
      {:ok, ko} = Resolver.resolve(snapshot, "diary_generation", prompt: "ko")
      assert ko.model == "google/gemini-3.6-flash"
      assert ko.prompt == "ko"
      assert ko.effective_params == %{"temperature" => 0.4}

      assert ko.effective_provider_options == %{
               "only" => ["google-ai-studio", "google-vertex"],
               "allow_fallbacks" => true
             }

      assert ko.provider == :openrouter
      assert ko.deployment_id == map["deployments"]["diary_generation"]["id"]
      assert ko.deployment_revision == 1

      assert [%{role: "system", content: ko_system}, %{role: "user"}] = ko.messages
      assert ko_system == Dump.task(dump, "diary_generation", "ko").system_prompt

      {:ok, default} = Resolver.resolve(snapshot, "diary_generation")
      assert default.prompt == "default"
      assert [%{role: "system", content: system}, %{role: "user"}] = default.messages
      assert system == Dump.task(dump, "diary_generation", nil).system_prompt
      assert default.model == ko.model

      # An unpinned name is an error, not a silent fallback
      assert {:error, :unknown_prompt} =
               Resolver.resolve(snapshot, "diary_generation", prompt: "ja")

      assert {:ok, ["default", "ko"]} = Resolver.prompt_names(snapshot, "diary_generation")

      # provider.only: null contract survives (gpt-5.4 has providers null) — here the free default
      # row is gemini, so chat_response is gemini too (the plan hierarchy collapsed)
      {:ok, chat} = Resolver.resolve(snapshot, "chat_response")
      assert chat.model == "google/gemini-3.6-flash"
      assert chat.effective_params == %{"temperature" => 0.7}
      assert [%{role: "system"}] = chat.messages

      # voice: text_template per language, Groq
      {:ok, stt} = Resolver.resolve(snapshot, "voice_transcription", prompt: "ko")
      assert stt.provider == :groq
      assert stt.model == "whisper-large-v3"
      assert stt.text_template == Dump.task(dump, "voice_transcription", "ko").system_prompt

      # transcript_revision default row: escaped system prompt renders back to the original
      {:ok, rev} = Resolver.resolve(snapshot, "transcript_revision")
      [%{content: escaped} | _] = rev.messages
      assert escaped =~ ~s|{{ "{{" }}|

      assert {:ok, Dump.task(dump, "transcript_revision", nil).system_prompt} ==
               PromptOnSDK.Template.render(escaped, %{})

      # embedding: no prompt, model attribution only
      {:ok, embed} = Resolver.resolve(snapshot, "diary_embedding")
      assert embed.model == "openai/text-embedding-3-small"
      assert embed.messages == nil
      assert embed.prompt == nil

      # §12.2 step 9 — exhaustive (task, language) comparison
      assert Verify.compare(dump, map) == []
      assert Verify.compare(dump, snapshot) == []
      assert length(Verify.cases(dump)) >= 8
      assert %{use_case: "diary_generation", language: "ko", prompt: "ko"} in Verify.cases(dump)
      assert %{use_case: "chat_response", language: "xx", prompt: "default"} in Verify.cases(dump)
    end

    test "Verify.compare detects divergence after a PromptOn-side edit", %{
      dump: dump,
      plan: plan,
      org: org,
      actor: actor
    } do
      summary = import!(plan, org, actor)
      scope = [actor: actor, tenant: summary.project_id]

      # Commit a new revision that raises mood_inference's temperature → the resolution diverges
      # from HeyDiary
      {:ok, mood} = Prompts.get_use_case_by_key("mood_inference", scope)
      {:ok, live} = Deployments.current_deployment(mood.id, summary.environment_id, scope)

      {:ok, _} =
        Deployments.commit_deployment(
          %{
            use_case_id: mood.id,
            environment_id: summary.environment_id,
            model_id: live.model_id,
            params: %{"temperature" => 0.9},
            provider_options: live.provider_options,
            prompt_pins: live.prompt_pins
          },
          scope
        )

      {map, _} = snapshot!(summary, actor)
      mismatches = Verify.compare(dump, map)
      assert mismatches != []

      assert Enum.all?(
               mismatches,
               &(&1.use_case == "mood_inference" and &1.field == :temperature)
             )

      assert %{heydiary: 0.1, prompton: 0.9} = hd(mismatches)
    end
  end

  describe "Export.sql/1 round trip (lossy)" do
    test "regenerates ai_models / ai_tasks / plan_ai_models from the single pin", %{
      dump: dump,
      plan: plan,
      org: org,
      actor: actor
    } do
      summary = import!(plan, org, actor)
      {map, _} = snapshot!(summary, actor)
      sql = Export.sql(map)

      # The lossiness warning is stamped at the top of the SQL
      assert String.starts_with?(sql, "-- WARNING: this export is LOSSY.")
      assert sql =~ "every plan below gets the same"
      assert sql =~ "BEGIN;"
      assert String.ends_with?(sql, "COMMIT;\n")

      # ai_models: only the openrouter models the pins point at (whisper/embedding excluded)
      assert sql =~
               "INSERT INTO ai_models (id, model, display_name, description_key, providers) VALUES (gen_random_uuid(), 'google/gemini-3.6-flash', 'Gemini 3.6 Flash'"

      assert sql =~ ~s|'["google-ai-studio","google-vertex"]'::jsonb|
      assert sql =~ "'openai/gpt-oss-120b'"
      refute sql =~ "whisper-large-v3'"
      refute sql =~ "text-embedding-3-small"

      # The plan hierarchy collapsed, so no pin points at the pro/max-only models
      refute sql =~ "'anthropic/claude-sonnet-4.5'"
      refute sql =~ "'openai/gpt-5.4'"

      # ai_tasks: the pin's prompt names → (task, language). The original (unescaped) comes back.
      for t <- dump.ai_tasks, t.task_name != "chat_response" or is_nil(t.language) do
        escaped_prompt = String.replace(t.system_prompt, "'", "''")

        assert sql =~
                 "language IS NOT DISTINCT FROM #{if t.language, do: "'#{t.language}'", else: "NULL"}",
               "no ai_tasks upsert for #{t.task_name}/#{t.language}"

        assert sql =~ "SET system_prompt = '#{escaped_prompt}'",
               "prompt of #{t.task_name}/#{t.language} missing"
      end

      assert sql =~ "SELECT gen_random_uuid(), 'diary_generation', NULL, "
      assert sql =~ "SELECT gen_random_uuid(), 'diary_generation', 'ko', "
      # the {{date}} placeholder comes back unescaped
      assert sql =~ "placeholders such as {{date}} or {% now %} untouched"
      refute sql =~ ~s|{{ "{{" }}|

      # plan_ai_models: one **identical** row per plan (is_default = true, sort_order 0)
      for plan_name <- ~w(free pro max) do
        assert sql =~
                 "SELECT gen_random_uuid(), '#{plan_name}', 'diary_generation', (SELECT id FROM ai_models WHERE model = 'google/gemini-3.6-flash'), true, 0.4, true, 0"
      end

      assert sql =~
               "SELECT gen_random_uuid(), 'free', 'mood_inference', (SELECT id FROM ai_models WHERE model = 'openai/gpt-oss-120b'), false, 0.1, true, 0"

      # Neither user-selectable (non-default) rows nor the original plan_ai_models.id are
      # reproduced
      refute sql =~ "ON CONFLICT (id) DO UPDATE"
      refute sql =~ "c3d4e5f6-0000-4000-8000-000000000307"
      refute sql =~ ", false, 0)"

      # Logs-only / derived use cases have no HeyDiary rows
      refute sql =~ "diary_content_removal"
      refute sql =~ "diary_embedding"
      refute sql =~ "'voice_transcription', (SELECT"

      # every INSERT/UPDATE statement terminates with ';' (multi-line prompts included)
      assert length(Regex.scan(~r/;\n/, sql)) ==
               length(Regex.scan(~r/^(INSERT|UPDATE|BEGIN|COMMIT)/m, sql))
    end
  end
end
