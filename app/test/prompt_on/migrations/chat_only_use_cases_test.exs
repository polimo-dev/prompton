defmodule PromptOn.Migrations.ChatOnlyUseCasesTest do
  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures

  alias PromptOn.Prompts.UseCase
  alias PromptOn.Repo

  test "archives unsupported use cases once without rewriting their stored history" do
    project = project_fixture()
    chat = use_case_fixture(project)
    text = use_case_fixture(project)
    embedding = use_case_fixture(project)
    archived = use_case_fixture(project)
    version = prompt_version_fixture(text)
    environment = environment(project, "production")
    model = model_fixture(project)

    deployment_fixture(text, environment, %{
      model_id: model.id,
      prompt_pins: %{"default" => version.id}
    })

    # Seed the shapes accepted before the cutover, without reopening legacy creation actions.
    query!("UPDATE use_cases SET kind = 'text' WHERE id = $1", [uuid(text.id)])
    query!("UPDATE use_cases SET kind = 'embedding' WHERE id = $1", [uuid(embedding.id)])

    query!(
      "UPDATE use_cases SET kind = 'text', archived_at = '2026-01-01 00:00:00' WHERE id = $1",
      [uuid(archived.id)]
    )

    query!(
      "UPDATE prompt_versions SET messages = '{}', text_template = $1 WHERE id = $2",
      ["Preserve {{ input }} exactly.\n", uuid(version.id)]
    )

    query!("UPDATE prompts SET draft = $1 WHERE use_case_id = $2", [
      %{"engine" => "liquid", "messages" => [], "text_template" => "Unsaved {{ input }}"},
      uuid(text.id)
    ])

    for {use_case, kind} <- [{text, "text"}, {embedding, "embedding"}] do
      assert %{accepted: 1, rejected: []} =
               ingest_fixture(project, [generation_payload_fixture(use_case, %{"kind" => kind})])
    end

    before_history = history(project.id)

    statement =
      UseCase
      |> AshPostgres.DataLayer.Info.custom_statements()
      |> Enum.find(&(&1.name == :archive_non_chat_use_cases))

    query!(statement.up)
    first = use_cases(project.id)
    assert Map.fetch!(first, chat.id) == ["chat", nil]
    assert ["text", %NaiveDateTime{}] = Map.fetch!(first, text.id)
    assert ["embedding", %NaiveDateTime{}] = Map.fetch!(first, embedding.id)
    assert Map.fetch!(first, archived.id) == ["text", ~N[2026-01-01 00:00:00.000000]]
    assert history(project.id) == before_history

    query!(statement.up)
    assert use_cases(project.id) == first

    # Rolling back the application must not silently reactivate incompatible API call sites.
    query!(statement.down)
    assert use_cases(project.id) == first
    assert history(project.id) == before_history

    for {use_case, kind} <- [{text, "text"}, {embedding, "embedding"}] do
      log = generation_payload_fixture(use_case, %{"kind" => kind})
      assert %{accepted: 1, rejected: []} = ingest_fixture(project, [log])
      generation = PromptOn.Observability.get_generation!(log["id"], scope(project))
      assert to_string(generation.kind) == kind
      assert generation.use_case_id == use_case.id
    end
  end

  defp use_cases(project_id) do
    query!("SELECT id, kind, archived_at FROM use_cases WHERE project_id = $1", [uuid(project_id)]).rows
    |> Map.new(fn [id, kind, archived_at] -> {Ecto.UUID.load!(id), [kind, archived_at]} end)
  end

  defp history(project_id) do
    for table <- ~w(prompts prompt_versions deployments generations generation_payloads) do
      order = if table == "generation_payloads", do: "generation_id", else: "id"

      query!("SELECT * FROM #{table} WHERE project_id = $1 ORDER BY #{order}", [uuid(project_id)]).rows
    end
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
  defp query!(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
