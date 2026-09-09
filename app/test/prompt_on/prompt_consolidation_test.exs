defmodule PromptOn.PromptConsolidationTest do
  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures
  require Ash.Query

  alias PromptOn.{Deployments, PromptConsolidation, Repo}
  alias PromptOn.Deployments.Deployment
  alias PromptOn.PromptConsolidation.Template, as: Merge
  alias PromptOn.Prompts.{Prompt, PromptVersion, UseCase}

  test "preserves immutable history, each environment's pins, and unpublished drafts independently" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    canonical = default_prompt(use_case)
    model = model_fixture(project)
    first = prompt_version_fixture(use_case, %{messages: messages("한국어 첫 {{ input }}\n")})
    english = legacy_version(use_case, "en", "English first {{ input }}\n")
    old = legacy_deployment(use_case, environment(project), model, first, english)
    second = prompt_version_fixture(use_case, %{messages: messages("한국어 둘 {{ input }}\n")})
    current = legacy_deployment(use_case, environment(project), model, second, english)
    staging = legacy_deployment(use_case, environment(project, "staging"), model, first, english)

    default_draft = Prompt.draft_map(:liquid, messages("작성 중 {{ input }}\n"), nil)
    english_draft = Prompt.draft_map(:liquid, messages("Draft {{ input }}\n"), nil)
    query!("UPDATE prompts SET draft = $1 WHERE id = $2", [default_draft, uuid(canonical.id)])

    query!("UPDATE prompts SET draft = $1 WHERE id = $2", [english_draft, uuid(english.prompt_id)])

    query!("UPDATE models SET status = 'deprecated' WHERE id = $1", [uuid(model.id)])
    versions_before = rows("prompt_versions", project.id)
    deployments_before = rows("deployments", project.id)

    assert [%{archived_prompts: 1, environments: 2, variables: ["language"]}] =
             PromptConsolidation.run!()

    assert Map.take(rows("prompt_versions", project.id), Map.keys(versions_before)) ==
             versions_before

    assert Map.take(rows("deployments", project.id), Map.keys(deployments_before)) ==
             deployments_before

    for source <- [current, staging] do
      latest = latest_deployment(source, project)
      assert latest.revision == source.revision + 1
      assert latest.model_id == source.model_id
      assert latest.params == source.params
      assert latest.provider_options == source.provider_options
      assert Map.keys(latest.prompt_pins) == ["default"]
      assert_preserved(source, latest.prompt_pins, project)
    end

    assert {:ok, historical_pins} = PromptConsolidation.pins_for(old, scope(project))
    assert_preserved(old, historical_pins, project)
    # Reactivation is explicit and independent from migration's preservation of the live model.
    query!("UPDATE models SET status = 'active' WHERE id = $1", [uuid(model.id)])
    assert {:ok, rollback} = Deployments.rollback_deployment(old.id, %{}, scope(project))
    assert rollback.prompt_pins == historical_pins
    assert_preserved(old, rollback.prompt_pins, project)

    merged = Ash.get!(Prompt, canonical.id, scope(project))
    archived = Ash.get!(Prompt, english.prompt_id, scope(project))
    assert archived.archived_at
    assert archived.draft == english_draft
    assert render(merged.draft, %{"input" => "A"}) == render(default_draft, %{"input" => "A"})

    assert render(merged.draft, %{"language" => "en", "input" => "A"}) ==
             render(english_draft, %{"input" => "A"})

    backups =
      PromptVersion |> Ash.Query.filter(prompt_id == ^canonical.id) |> Ash.read!(scope(project))

    assert Enum.any?(
             backups,
             &(render(&1, %{"input" => "A"}) == render(default_draft, %{"input" => "A"}))
           )

    updated = Ash.get!(UseCase, use_case.id, scope(project))
    assert Enum.any?(updated.input_schema, &(&1.name == "language" and not &1.required?))

    after_upgrade =
      {rows("prompts", project.id), rows("prompt_versions", project.id),
       rows("deployments", project.id)}

    assert PromptConsolidation.run!() == []

    assert after_upgrade ==
             {rows("prompts", project.id), rows("prompt_versions", project.id),
              rows("deployments", project.id)}
  end

  test "dry run validates but leaves every row unchanged" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    prompt_version_fixture(use_case)
    legacy_version(use_case, "en", "English {{ input }}")

    before =
      {rows("prompts", project.id), rows("prompt_versions", project.id),
       rows("use_cases", project.id)}

    assert [%{archived_prompts: 1}] = PromptConsolidation.run!(dry_run: true)

    assert before ==
             {rows("prompts", project.id), rows("prompt_versions", project.id),
              rows("use_cases", project.id)}
  end

  test "archived variants in past revisions remain available for rollback after current became default-only" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    model = model_fixture(project)
    default = prompt_version_fixture(use_case)
    english = legacy_version(use_case, "en", "Old English {{ input }}")
    old = legacy_deployment(use_case, environment(project), model, default, english)

    current =
      deployment_fixture(use_case, environment(project), %{
        model_id: model.id,
        prompt_pins: %{"default" => default.id}
      })

    query!("UPDATE prompts SET archived_at = now() WHERE id = $1", [uuid(english.prompt_id)])
    assert [%{archived_prompts: 0}] = PromptConsolidation.run!()
    assert latest_deployment(current, project).id == current.id
    assert {:ok, pins} = PromptConsolidation.pins_for(old, scope(project))
    assert_preserved(old, pins, project)
    assert PromptConsolidation.run!() == []
  end

  test "an existing variable of incompatible type blocks selector inference before mutation" do
    project = project_fixture()
    use_case = use_case_fixture(project, %{input_schema: [%{name: "language", type: :boolean}]})
    prompt_version_fixture(use_case)
    english = legacy_version(use_case, "en", "English {{ input }}")

    assert_raise ArgumentError, ~r/selector language conflicts/, fn ->
      PromptConsolidation.run!()
    end

    assert is_nil(Ash.get!(Prompt, english.prompt_id, scope(project)).archived_at)
  end

  test "incompatible messages fail without archiving or rewriting drafts" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    prompt_version_fixture(use_case, %{messages: [%{role: :system, content: "Only one"}]})
    legacy_version(use_case, "en", "Two messages")
    before = {rows("prompts", project.id), rows("prompt_versions", project.id)}
    assert_raise ArgumentError, ~r/message shape/, fn -> PromptConsolidation.run!() end
    assert before == {rows("prompts", project.id), rows("prompt_versions", project.id)}
  end

  test "renamed historical pin ownership follows version IDs" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    default = prompt_version_fixture(use_case)
    english = legacy_version(use_case, "en", "English {{ input }}")

    old =
      legacy_deployment(use_case, environment(project), model_fixture(project), default, english)

    query!("UPDATE prompts SET name = 'english' WHERE id = $1", [uuid(english.prompt_id)])
    assert [_] = PromptConsolidation.run!()
    assert {:ok, pins} = PromptConsolidation.pins_for(old, scope(project))
    merged = Ash.get!(PromptVersion, pins["default"], scope(project))

    assert render(merged, %{"variant" => "en", "input" => "A"}) ==
             render(english, %{"input" => "A"})

    assert PromptConsolidation.run!() == []
  end

  test "an independent existing language input survives under a distinct selector" do
    project = project_fixture()
    use_case = use_case_fixture(project)

    default =
      prompt_version_fixture(use_case, %{
        messages: messages("Original {{ language }} {{ input }}")
      })

    english = legacy_version(use_case, "en", "English {{ language }} {{ input }}")

    old =
      legacy_deployment(use_case, environment(project), model_fixture(project), default, english)

    assert [%{variables: ["prompt_language"]}] = PromptConsolidation.run!()
    assert {:ok, pins} = PromptConsolidation.pins_for(old, scope(project))
    merged = Ash.get!(PromptVersion, pins["default"], scope(project))
    vars = %{"language" => "independent value", "input" => "A", "prompt_language" => "en"}
    assert render(merged, vars) == render(english, vars)
    assert PromptConsolidation.run!() == []
  end

  test "empty drafts fail preflight rather than passing dry run and failing on apply" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    prompt_version_fixture(use_case)
    english = legacy_version(use_case, "en", "English {{ input }}")

    for id <- [default_prompt(use_case).id, english.prompt_id] do
      query!("UPDATE prompts SET draft = $1 WHERE id = $2", [
        Prompt.draft_map(:liquid, [], nil),
        uuid(id)
      ])
    end

    assert_raise ArgumentError, ~r/empty draft/, fn -> PromptConsolidation.run!(dry_run: true) end
    assert is_nil(Ash.get!(Prompt, english.prompt_id, scope(project)).archived_at)
  end

  defp legacy_version(use_case, name, content) do
    # Seed legacy records through SQL; current authoring correctly rejects named prompts.
    id = Ash.UUIDv7.generate()

    query!(
      "INSERT INTO prompts (id, project_id, use_case_id, name, inserted_at, updated_at) VALUES ($1, $2, $3, $4, now(), now())",
      [uuid(id), uuid(use_case.project_id), uuid(use_case.id), name]
    )

    version = prompt_version_fixture(use_case, %{messages: messages(content)})

    query!("UPDATE prompt_versions SET prompt_id = $1, number = 1 WHERE id = $2", [
      uuid(id),
      uuid(version.id)
    ])

    %{version | prompt_id: id, number: 1}
  end

  defp legacy_deployment(use_case, env, model, default, english) do
    deployment =
      deployment_fixture(use_case, env, %{
        model_id: model.id,
        prompt_pins: %{"default" => default.id},
        params: %{"temperature" => 0.4},
        provider_options: %{"only" => ["Anthropic"]}
      })

    pins = %{"default" => default.id, "en" => english.id}
    query!("UPDATE deployments SET prompt_pins = $1 WHERE id = $2", [pins, uuid(deployment.id)])
    %{deployment | prompt_pins: pins}
  end

  defp latest_deployment(source, project) do
    Deployment
    |> Ash.Query.filter(
      use_case_id == ^source.use_case_id and environment_id == ^source.environment_id
    )
    |> Ash.Query.sort(revision: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope(project))
  end

  defp assert_preserved(source, pins, project) do
    merged = Ash.get!(PromptVersion, pins["default"], scope(project))

    for {name, id} <- source.prompt_pins do
      original = Ash.get!(PromptVersion, id, scope(project))
      variables = %{"input" => "payload", "language" => if(name == "en", do: "en", else: "ko")}
      assert render(merged, variables) == render(original, variables)
    end
  end

  defp messages(content),
    do: [%{role: :system, content: content}, %{role: :user, content: "{{ input }}"}]

  defp render(source, vars) do
    content = Merge.content(source)
    PromptOnSDK.Template.render_messages(content.messages, vars, engine: content.engine)
  end

  defp rows(table, project_id),
    do:
      query!("SELECT id, to_jsonb(t) FROM #{table} t WHERE project_id = $1", [uuid(project_id)]).rows
      |> Map.new(fn [id, row] -> {id, row} end)

  defp uuid(id), do: Ecto.UUID.dump!(id)
  defp query!(sql, params), do: Repo.query!(sql, params)
end
