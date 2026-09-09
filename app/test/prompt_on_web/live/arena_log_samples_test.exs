defmodule PromptOnWeb.ArenaLogSamplesTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.{Observability, Projects}
  alias PromptOn.Observability.GenerationPayload
  alias PromptOnWeb.ArenaLogSamples

  setup do
    user = user_fixture()
    project = project_fixture(%{user: user})
    use_case = use_case_fixture(project, %{key: "support_reply"})

    %{user: user, project: project, use_case: use_case, scope: [tenant: project.id, actor: user]}
  end

  test "lists bounded recent live logs with stored unexpired payload metadata only", ctx do
    logs = stored_generations_fixture(ctx.project, ctx.use_case, 22)

    assert {:ok, samples} = ArenaLogSamples.list(ctx.use_case, ctx.scope)
    assert length(samples) == 20

    assert Enum.map(samples, & &1.id) ==
             logs |> Enum.reverse() |> Enum.take(20) |> Enum.map(& &1.id)

    newest = hd(samples)
    assert newest.model == "anthropic/claude-sonnet-4"
    assert newest.provider == :openrouter
    assert newest.status == :ok
    assert newest.started_at == List.last(logs).started_at
    refute Map.has_key?(newest, :variables)
    refute Map.has_key?(newest, :input)
    refute Map.has_key?(newest, :output)

    payload = Observability.get_payload!(newest.id, ctx.scope)
    assert %Ash.NotLoaded{} = payload.variables
  end

  test "loads exact variables for the selected same-use-case live sample", ctx do
    variables = %{
      "enabled" => false,
      "count" => 0,
      "profile" => %{"tier" => "free", "flags" => [false, 0, ""]},
      "lines" => ["a", "b"]
    }

    [log] =
      stored_generations_fixture(ctx.project, ctx.use_case, 1, %{
        "input" => %{
          "variables" => variables,
          "messages" => [%{"role" => "user", "content" => "rendered"}],
          "truncated" => false
        }
      })

    assert {:ok, ^variables} = ArenaLogSamples.variables(ctx.use_case, log.id, ctx.scope)
  end

  test "matches legacy rows whose use_case_id is nil by key inside the same tenant", ctx do
    [log] = stored_generations_fixture(ctx.project, ctx.use_case, 1)

    PromptOn.Repo.query!("UPDATE generations SET use_case_id = NULL WHERE id = $1", [uuid(log.id)])

    assert {:ok, [%{id: id}]} = ArenaLogSamples.list(ctx.use_case, ctx.scope)
    assert id == log.id

    assert {:ok, %{"input" => "hello"}} =
             ArenaLogSamples.variables(ctx.use_case, log.id, ctx.scope)
  end

  test "excludes other projects, other use cases, playground logs, and unavailable payload states",
       ctx do
    other_use_case = use_case_fixture(ctx.project, %{key: "billing_reply"})
    other_project = project_fixture(%{user: ctx.user})
    other_project_use_case = use_case_fixture(other_project, %{key: ctx.use_case.key})

    [visible] = stored_generations_fixture(ctx.project, ctx.use_case, 1)
    [same_project_other_use_case] = stored_generations_fixture(ctx.project, other_use_case, 1)
    [_other_project_log] = stored_generations_fixture(other_project, other_project_use_case, 1)
    [playground] = stored_generations_fixture(ctx.project, ctx.use_case, 1)

    [dropped] =
      stored_generations_fixture(ctx.project, ctx.use_case, 1, %{"input" => nil, "output" => nil})

    PromptOn.Repo.query!("UPDATE generations SET source = 'playground' WHERE id = $1", [
      uuid(playground.id)
    ])

    assert {:ok, samples} = ArenaLogSamples.list(ctx.use_case, ctx.scope)
    assert Enum.map(samples, & &1.id) == [visible.id]

    assert {:error, :unavailable} =
             ArenaLogSamples.variables(ctx.use_case, same_project_other_use_case.id, ctx.scope)

    assert {:error, :unavailable} =
             ArenaLogSamples.variables(ctx.use_case, playground.id, ctx.scope)

    assert {:error, :unavailable} =
             ArenaLogSamples.variables(ctx.use_case, dropped.id, ctx.scope)
  end

  test "excludes expired, purged, hashed, and dropped payloads", ctx do
    [fresh] = stored_generations_fixture(ctx.project, ctx.use_case, 1)
    [expired] = stored_generations_fixture(ctx.project, ctx.use_case, 1)
    [purged] = stored_generations_fixture(ctx.project, ctx.use_case, 1)

    expire_payload(purged.id)

    assert {:ok, %{deleted: 1}} =
             Observability.purge_expired_payloads(%{batch_size: 1}, scope(ctx.project))

    expire_payload(expired.id)

    {:ok, _project} =
      Projects.set_project_payload_policy(ctx.project, %{payload_policy: %{mode: :hash}},
        actor: system_actor()
      )

    [hashed] = stored_generations_fixture(ctx.project, ctx.use_case, 1)

    {:ok, _project} =
      Projects.set_project_payload_policy(ctx.project, %{payload_policy: %{mode: :none}},
        actor: system_actor()
      )

    [dropped] = stored_generations_fixture(ctx.project, ctx.use_case, 1)

    assert {:ok, samples} = ArenaLogSamples.list(ctx.use_case, ctx.scope)
    assert Enum.map(samples, & &1.id) == [fresh.id]

    for id <- [expired.id, purged.id, hashed.id, dropped.id] do
      assert {:error, :unavailable} = ArenaLogSamples.variables(ctx.use_case, id, ctx.scope)
    end

    assert {:ok, %GenerationPayload{}} = Observability.get_payload(expired.id, ctx.scope)
    assert {:ok, nil} = Observability.get_payload(purged.id, ctx.scope)
  end

  test "uses caller scope for project access", ctx do
    [log] = stored_generations_fixture(ctx.project, ctx.use_case, 1)
    stranger_scope = [tenant: ctx.project.id, actor: user_fixture()]

    assert {:ok, []} = ArenaLogSamples.list(ctx.use_case, stranger_scope)

    assert {:error, :unavailable} =
             ArenaLogSamples.variables(ctx.use_case, log.id, stranger_scope)
  end

  defp expire_payload(id) do
    PromptOn.Repo.query!(
      "UPDATE generation_payloads SET expires_at = now() - interval '1 day' WHERE generation_id = $1",
      [uuid(id)]
    )
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
