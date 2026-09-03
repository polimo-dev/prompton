defmodule PromptOnWeb.API.V1.SnapshotControllerTest do
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Deployments.{Snapshot, SnapshotCache}

  setup do
    hd = heydiary_project_fixture()
    {api_key, raw} = api_key_fixture(hd.project)
    %{hd: hd, api_key: api_key, raw: raw}
  end

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer #{raw}")

  test "401 without a key", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/snapshot")
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)

    conn = build_conn() |> authed("ptn_production_nope") |> get(~p"/api/v1/snapshot")
    assert json_response(conn, 401)
  end

  test "403 with a key lacking the resolve scope", %{conn: conn, hd: hd} do
    {_key, raw} = api_key_fixture(hd.project, scopes: [:logs])
    conn = conn |> authed(raw) |> get(~p"/api/v1/snapshot")
    assert %{"error" => %{"code" => "forbidden", "message" => msg}} = json_response(conn, 403)
    assert msg =~ "resolve"
  end

  test "200 with canonical body, ETag, Last-Modified, Cache-Control", %{
    conn: conn,
    hd: hd,
    api_key: api_key,
    raw: raw
  } do
    conn = conn |> authed(raw) |> get(~p"/api/v1/snapshot")
    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    {:ok, expected} = Snapshot.build(hd.production, actor: api_key, tenant: hd.project.id)
    assert conn.resp_body == expected.body
    assert get_resp_header(conn, "etag") == [~s("#{expected.etag}")]
    assert [last_modified] = get_resp_header(conn, "last-modified")
    assert last_modified =~ ~r/^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$/
    assert get_resp_header(conn, "cache-control") == ["max-age=30"]

    body = Jason.decode!(conn.resp_body)
    assert body["schema_version"] == 3
    assert body["environment"] == "production"

    # A revision is a **pin**: one model + one version per prompt name (no rules, no targets).
    diary = body["deployments"]["diary_generation"]
    assert diary["id"] == hd.deployments.diary.id
    assert diary["revision"] == 1
    assert diary["model_id"] == hd.models.sonnet.id

    assert diary["prompt_pins"] == %{
             "default" => hd.prompt_versions.diary.id,
             "ko" => hd.prompt_versions.diary_ko.id
           }

    refute Map.has_key?(diary, "rules")
    refute Map.has_key?(body, "dimensions")
    assert {:ok, _data, []} = PromptOnSDK.SnapshotData.decode_json(conn.resp_body)
  end

  test "?environment= picks the environment; the same project key reads both", %{
    conn: conn,
    hd: hd,
    raw: raw
  } do
    # Defaults to production
    body = json_response(conn |> authed(raw) |> get(~p"/api/v1/snapshot"), 200)
    assert body["environment"] == "production"

    # When given, that environment; keys are per project, so the same key reads it (2026-09-01)
    staging =
      deployment_fixture(hd.use_cases.chat, hd.staging, %{
        model_id: hd.models.opus.id,
        prompt_pins: %{"default" => hd.prompt_versions.chat.id}
      })

    conn = build_conn() |> authed(raw) |> get(~p"/api/v1/snapshot?environment=staging")
    body = json_response(conn, 200)
    assert body["environment"] == "staging"
    assert Map.keys(body["deployments"]) == ["chat_response"]
    assert body["deployments"]["chat_response"]["id"] == staging.id

    # The two environments' ETags differ (their contents differ)
    [production_etag] =
      build_conn() |> authed(raw) |> get(~p"/api/v1/snapshot") |> get_resp_header("etag")

    [staging_etag] = get_resp_header(conn, "etag")
    refute production_etag == staging_etag
  end

  test "an unknown environment is 404, a blank one is 400", %{conn: conn, raw: raw} do
    conn2 = build_conn() |> authed(raw) |> get(~p"/api/v1/snapshot?environment=canary")

    assert %{"error" => %{"code" => "not_found", "details" => %{"environment" => "canary"}}} =
             json_response(conn2, 404)

    conn3 = conn |> authed(raw) |> get(~p"/api/v1/snapshot?environment=")

    assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
             json_response(conn3, 400)

    assert message =~ "environment"
  end

  test "304 with matching If-None-Match (quoted, weak, list)", %{conn: conn, raw: raw} do
    first = conn |> authed(raw) |> get(~p"/api/v1/snapshot")
    [etag] = get_resp_header(first, "etag")

    for header <- [etag, "W/#{etag}", ~s("sha256-other", #{etag})] do
      conn =
        build_conn()
        |> authed(raw)
        |> put_req_header("if-none-match", header)
        |> get(~p"/api/v1/snapshot")

      assert conn.status == 304, "expected 304 for #{header}"
      assert conn.resp_body == ""
      assert get_resp_header(conn, "etag") == [etag]
    end

    conn =
      build_conn()
      |> authed(raw)
      |> put_req_header("if-none-match", ~s("sha256-stale"))
      |> get(~p"/api/v1/snapshot")

    assert conn.status == 200
  end

  test "an environment with no deployment is an empty snapshot, not an error", %{
    conn: conn,
    raw: raw
  } do
    conn = conn |> authed(raw) |> get(~p"/api/v1/snapshot?environment=staging")
    body = json_response(conn, 200)
    assert body["environment"] == "staging"
    assert body["deployments"] == %{}
    assert body["prompt_versions"] == %{}
  end

  # Polling is the normal use of this endpoint, so the second request does not rebuild the snapshot
  # (`PromptOn.Deployments.SnapshotCache`). Verified through telemetry, looking only at the events
  # for this environment id.
  test "the second request is served from the snapshot cache", %{conn: conn, hd: hd, raw: raw} do
    SnapshotCache.invalidate(hd.production)
    environment_id = hd.production.id
    parent = self()
    handler = "snapshot-controller-cache-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:prompton, :snapshot_cache, :hit],
        [:prompton, :snapshot_cache, :miss]
      ],
      fn event, _measurements, %{environment_id: id}, _config ->
        if id == environment_id, do: send(parent, {:cache, List.last(event)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert (conn |> authed(raw) |> get(~p"/api/v1/snapshot")).status == 200
    assert_receive {:cache, :miss}

    second = build_conn() |> authed(raw) |> get(~p"/api/v1/snapshot")
    assert second.status == 200
    assert_receive {:cache, :hit}
    refute_receive {:cache, :miss}, 20
  end
end
