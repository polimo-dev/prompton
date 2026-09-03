defmodule PromptOn.Deployments.SnapshotCacheTest do
  # Runs synchronously: it touches the global ETS table and `:snapshot_cache_ttl_ms`
  # (Application env).
  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures

  alias PromptOn.Deployments.SnapshotCache

  @events [
    [:prompton, :snapshot_cache, :hit],
    [:prompton, :snapshot_cache, :miss],
    [:prompton, :snapshot_cache, :revalidate]
  ]

  setup do
    SnapshotCache.flush()

    project = project_fixture()
    production = environment(project, "production")
    use_case = use_case_fixture(project, %{key: "greeting"})
    model = model_fixture(project)
    version = prompt_version_fixture(use_case)

    _deployment =
      simple_deployment_fixture(use_case, production, %{model: model, prompt_version: version})

    handler = "snapshot-cache-#{System.unique_integer([:positive])}"
    :telemetry.attach_many(handler, @events, &__MODULE__.forward_event/4, self())

    on_exit(fn ->
      :telemetry.detach(handler)
      SnapshotCache.flush()
    end)

    %{
      project: project,
      production: production,
      use_case: use_case,
      model: model,
      version: version
    }
  end

  @doc false
  def forward_event(event, _measurements, metadata, pid), do: send(pid, {:cache, event, metadata})

  defp fetch(env, project),
    do: SnapshotCache.fetch(env, actor: system_actor(), tenant: project.id)

  test "the first fetch builds, the second serves from ETS without touching the database", %{
    project: project,
    production: production,
    use_case: use_case,
    model: model,
    version: version
  } do
    assert {:ok, first} = fetch(production, project)
    assert_receive {:cache, [:prompton, :snapshot_cache, :miss], _}
    assert Map.has_key?(first.data.deployments, "greeting")

    # The entry carries not only the decoded result but also the canonical body that
    # `GET /snapshot` sends as is.
    assert is_binary(first.body)
    assert PromptOn.CanonicalJSON.etag(first.body) == first.etag
    assert %DateTime{} = first.last_modified

    # Changing the DB within the TTL still yields the cached value = the second call did not
    # reassemble the snapshot.
    _revision_2 =
      deployment_fixture(use_case, production, %{
        model_id: model.id,
        prompt_pins: %{"default" => version.id},
        params: %{"temperature" => 0.9}
      })

    assert {:ok, second} = fetch(production, project)
    assert_receive {:cache, [:prompton, :snapshot_cache, :hit], _}
    refute_receive {:cache, [:prompton, :snapshot_cache, :miss], _}, 20

    assert second.etag == first.etag
    assert second.data.deployments["greeting"].revision == 1
  end

  test "an expired entry revalidates: same ETag reuses the decoded value, a change replaces it",
       %{
         project: project,
         production: production,
         use_case: use_case,
         model: model,
         version: version
       } do
    assert {:ok, first} = fetch(production, project)

    SnapshotCache.expire(production)
    assert {:ok, same} = fetch(production, project)
    assert_receive {:cache, [:prompton, :snapshot_cache, :revalidate], %{changed?: false}}
    assert same.etag == first.etag
    # the decoded result is reused as is (same entry, so identical structure)
    assert same.data == first.data
    assert same.body == first.body
    assert same.last_modified == first.last_modified

    _revision_2 =
      deployment_fixture(use_case, production, %{
        model_id: model.id,
        prompt_pins: %{"default" => version.id},
        params: %{"temperature" => 0.9}
      })

    SnapshotCache.expire(production)
    assert {:ok, changed} = fetch(production, project)
    assert_receive {:cache, [:prompton, :snapshot_cache, :revalidate], %{changed?: true}}
    refute changed.etag == first.etag
    refute changed.body == first.body
    assert changed.data.deployments["greeting"].revision == 2
  end

  test "invalidate drops the entry so the next fetch rebuilds", %{
    project: project,
    production: production
  } do
    assert {:ok, _first} = fetch(production, project)
    assert_receive {:cache, [:prompton, :snapshot_cache, :miss], _}

    SnapshotCache.invalidate(production)

    assert {:ok, _again} = fetch(production, project)
    assert_receive {:cache, [:prompton, :snapshot_cache, :miss], _}
  end

  test "a zero TTL revalidates on every fetch", %{project: project, production: production} do
    previous = Application.get_env(:prompton, :snapshot_cache_ttl_ms)
    Application.put_env(:prompton, :snapshot_cache_ttl_ms, 0)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:prompton, :snapshot_cache_ttl_ms),
        else: Application.put_env(:prompton, :snapshot_cache_ttl_ms, previous)
    end)

    assert SnapshotCache.ttl_ms() == 0
    assert {:ok, _} = fetch(production, project)
    assert {:ok, _} = fetch(production, project)
    assert_receive {:cache, [:prompton, :snapshot_cache, :revalidate], %{changed?: false}}
  end

  test "an archived project is not served from a stale entry", %{
    project: project,
    production: production
  } do
    assert {:ok, _first} = fetch(production, project)

    {:ok, _archived} =
      PromptOn.Projects.archive_project(project, %{}, actor: system_actor(), tenant: project.id)

    SnapshotCache.expire(production)
    assert {:error, :not_found} = fetch(production, project)
  end

  test "fetch accepts an environment id as well as a struct", %{
    project: project,
    production: production
  } do
    assert {:ok, entry} =
             SnapshotCache.fetch(production.id, actor: system_actor(), tenant: project.id)

    assert entry.data.environment == "production"
  end
end
