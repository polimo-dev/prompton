defmodule PromptOnWeb.API.V1.GenerationControllerTest do
  @moduledoc "POST /api/v1/generations (plan.md §6.4, docs/api.md)."

  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Observability

  setup %{conn: conn} do
    project = project_fixture()
    use_case = use_case_fixture(project, %{key: "diary_generation"})
    {api_key, raw} = api_key_fixture(project, scopes: [:resolve, :logs])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, project: project, use_case: use_case, api_key: api_key}
  end

  test "401 without a key" do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = post(conn, ~p"/api/v1/generations", Jason.encode!(%{"generations" => []}))
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "403 with a resolve-only key", %{project: project, use_case: use_case} do
    {_key, raw} = api_key_fixture(project, scopes: [:resolve])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/generations",
        Jason.encode!(%{"generations" => [generation_payload_fixture(use_case)]})
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    assert {:ok, %{results: []}} = Observability.list_generations(scope(project))
  end

  test "202 with accepted/duplicates/rejected for a mixed batch", %{
    conn: conn,
    project: project,
    use_case: use_case
  } do
    good = generation_payload_fixture(use_case)
    dup = good
    bad = generation_payload_fixture(use_case, %{"started_at" => "2020-01-01T00:00:00Z"})

    conn =
      post(conn, ~p"/api/v1/generations", Jason.encode!(%{"generations" => [good, dup, bad]}))

    assert %{
             "accepted" => 1,
             "duplicates" => 1,
             "rejected" => [
               %{"index" => 2, "id" => bad_id, "code" => "invalid_request", "message" => message}
             ]
           } = json_response(conn, 202)

    assert bad_id == bad["id"]
    assert message =~ "started_at"

    {:ok, %{results: [gen]}} = Observability.list_generations(scope(project))
    assert gen.id == good["id"]
    assert gen.environment_id == environment(project, "production").id

    # A resend is absorbed as a duplicate
    conn =
      post(
        recycle_keep_auth(conn),
        ~p"/api/v1/generations",
        Jason.encode!(%{"generations" => [good]})
      )

    assert %{"accepted" => 0, "duplicates" => 1, "rejected" => []} = json_response(conn, 202)
  end

  test "the environment is a request parameter, forced onto the whole batch", %{
    conn: conn,
    project: project,
    use_case: use_case
  } do
    payload = generation_payload_fixture(use_case)

    conn =
      post(
        conn,
        ~p"/api/v1/generations?environment=staging",
        Jason.encode!(%{"generations" => [payload]})
      )

    assert %{"accepted" => 1} = json_response(conn, 202)

    {:ok, %{results: [gen]}} = Observability.list_generations(scope(project))
    assert gen.environment_id == environment(project, "staging").id
  end

  test "an unknown environment is 404 and nothing is ingested", %{
    conn: conn,
    project: project,
    use_case: use_case
  } do
    conn =
      post(
        conn,
        ~p"/api/v1/generations?environment=canary",
        Jason.encode!(%{"generations" => [generation_payload_fixture(use_case)]})
      )

    assert %{"error" => %{"code" => "not_found", "details" => %{"environment" => "canary"}}} =
             json_response(conn, 404)

    assert {:ok, %{results: []}} = Observability.list_generations(scope(project))
  end

  test "400 when generations is not a list or missing, or over 200", %{
    conn: conn,
    use_case: use_case
  } do
    conn1 = post(conn, ~p"/api/v1/generations", Jason.encode!(%{"generations" => %{"id" => "x"}}))

    assert %{"error" => %{"code" => "invalid_request", "message" => msg}} =
             json_response(conn1, 400)

    assert msg =~ "list"

    conn2 = post(recycle_keep_auth(conn), ~p"/api/v1/generations", Jason.encode!(%{"nope" => []}))
    assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn2, 400)

    too_many = List.duplicate(generation_payload_fixture(use_case), 201)

    conn3 =
      post(
        recycle_keep_auth(conn),
        ~p"/api/v1/generations",
        Jason.encode!(%{"generations" => too_many})
      )

    assert %{"error" => %{"code" => "invalid_request", "message" => msg}} =
             json_response(conn3, 400)

    assert msg =~ "200"
  end

  test "payload is stored encrypted for a full-mode project", %{
    conn: conn,
    project: project,
    use_case: use_case
  } do
    p = generation_payload_fixture(use_case, %{"output" => %{"content" => "DIARY-BODY"}})
    conn = post(conn, ~p"/api/v1/generations", Jason.encode!(%{"generations" => [p]}))
    assert %{"accepted" => 1} = json_response(conn, 202)

    gen = Observability.get_generation!(p["id"], scope(project))
    assert gen.payload_state == :stored

    payload = Observability.get_payload!(p["id"], scope(project) ++ [load: [:output, :input]])
    assert payload.output == %{"content" => "DIARY-BODY"}
    assert payload.encrypted? == true

    %{rows: [[raw]]} =
      Ecto.Adapters.SQL.query!(
        PromptOn.Repo,
        "SELECT encrypted_output FROM generation_payloads WHERE generation_id = $1",
        [Ecto.UUID.dump!(p["id"])]
      )

    refute raw =~ "DIARY-BODY"
  end

  test "id owned by another project comes back as rejected code conflict", %{
    conn: conn,
    project: project,
    use_case: use_case
  } do
    other = project_fixture()
    taken = generation_payload_fixture(use_case_fixture(other, %{key: "k"}))
    assert %{accepted: 1} = ingest_fixture(other, [taken])

    mine = generation_payload_fixture(use_case)
    clash = generation_payload_fixture(use_case, %{"id" => taken["id"]})
    conn = post(conn, ~p"/api/v1/generations", Jason.encode!(%{"generations" => [mine, clash]}))

    assert %{
             "accepted" => 1,
             "duplicates" => 0,
             "rejected" => [%{"index" => 1, "code" => "conflict", "id" => id}]
           } = json_response(conn, 202)

    assert id == taken["id"]
    assert {:ok, %{results: [gen]}} = Observability.list_generations(scope(project))
    assert gen.id == mine["id"]
  end

  test "error envelopes never carry internal error text", %{conn: conn} do
    # Ash validation errors expose only the field messages
    invalid =
      Ash.Error.to_error_class([
        Ash.Error.Changes.InvalidAttribute.exception(field: :model, message: "must be present"),
        Ash.Error.Unknown.UnknownError.exception(error: "** (Postgrex.Error) secret db text")
      ])

    conn1 = PromptOnWeb.API.V1.FallbackController.call(json_conn(conn), {:error, invalid})
    body = json_response(conn1, 400)

    assert %{
             "error" => %{
               "code" => "invalid_request",
               "message" => "model: must be present",
               "details" => %{"errors" => [%{"field" => "model", "message" => "must be present"}]}
             }
           } = body

    refute inspect(body) =~ "secret db text"

    # Unknown errors get the generic wording
    unknown = Ash.Error.to_error_class([Ash.Error.Unknown.UnknownError.exception(error: "boom")])
    conn2 = PromptOnWeb.API.V1.FallbackController.call(json_conn(conn), {:error, unknown})

    assert %{"error" => %{"code" => "internal_error", "message" => "internal error"}} =
             json_response(conn2, 500)

    refute conn2.resp_body =~ "boom"

    conn3 =
      PromptOnWeb.API.V1.FallbackController.call(json_conn(conn), {:error, {:weird, "raw"}})

    assert %{"error" => %{"code" => "invalid_request", "message" => "invalid request"}} =
             json_response(conn3, 400)

    refute conn3.resp_body =~ "weird"
  end

  # Calling FallbackController directly (no controller in front) needs params/format prepared.
  defp json_conn(conn) do
    conn |> Plug.Conn.fetch_query_params() |> Phoenix.Controller.put_format("json")
  end

  test "empty batch is accepted", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/generations", Jason.encode!(%{"generations" => []}))
    assert %{"accepted" => 0, "duplicates" => 0, "rejected" => []} = json_response(conn, 202)
  end

  defp recycle_keep_auth(conn) do
    auth = get_req_header(conn, "authorization")

    conn
    |> recycle()
    |> put_req_header("authorization", hd(auth))
    |> put_req_header("content-type", "application/json")
  end
end
