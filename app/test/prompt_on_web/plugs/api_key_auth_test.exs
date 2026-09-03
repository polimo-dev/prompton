defmodule PromptOnWeb.Plugs.ApiKeyAuthTest do
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Projects
  alias PromptOnWeb.Plugs.ApiKeyAuth

  setup do
    project = project_fixture()
    {api_key, raw} = api_key_fixture(project)
    %{project: project, api_key: api_key, raw: raw}
  end

  # Calling the plug directly requires params to be fetched (the error render looks at `_format`).
  defp call(conn, raw \\ nil) do
    conn = if raw, do: put_req_header(conn, "authorization", "Bearer #{raw}"), else: conn
    conn |> fetch_query_params() |> Phoenix.Controller.put_format("json") |> ApiKeyAuth.call([])
  end

  test "by_raw_key finds the key without an actor; the key is project-level (no environment)",
       %{api_key: api_key, raw: raw} do
    assert {:ok, %Projects.ApiKey{id: id}} = Projects.api_key_by_raw_key(raw)
    assert id == api_key.id
    refute Map.has_key?(api_key, :environment_id)
  end

  test "sets actor and tenant, and loads the project's environments once", %{
    conn: conn,
    api_key: api_key,
    raw: raw,
    project: project
  } do
    conn = call(conn, raw)
    refute conn.halted
    assert %Projects.ApiKey{id: id} = Ash.PlugHelpers.get_actor(conn)
    assert id == api_key.id
    assert Ash.PlugHelpers.get_tenant(conn) == project.id
    assert conn.assigns.api_key.id == api_key.id
    refute Map.has_key?(conn.assigns, :current_environment)

    # The request path must be able to find environment slug → id without the DB (the proxy-mode
    # hot path).
    slugs = Enum.map(conn.assigns.api_key.project.environments, & &1.slug)
    assert "production" in slugs
    assert "staging" in slugs
  end

  test "401 for missing/invalid/revoked keys",
       %{conn: conn, raw: raw, api_key: api_key} do
    assert %{halted: true, status: 401} = call(conn)
    assert %{halted: true, status: 401} = call(conn, "ptn_production_nope")

    {:ok, _} = Projects.revoke_api_key(api_key, actor: system_actor())
    assert %{halted: true, status: 401} = call(conn, raw)
  end

  test "401 once the key's project is archived (decision #11)", %{conn: conn} do
    project = project_fixture()
    {_key, raw} = api_key_fixture(project, scopes: [:resolve, :logs])
    refute call(conn, raw).halted

    {:ok, _} = Projects.archive_project(project, actor: system_actor())

    assert %{halted: true, status: 401} = conn = call(conn, raw)
    assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(conn.resp_body)
  end
end
