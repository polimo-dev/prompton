defmodule PromptOnWeb.ErrorJSONTest do
  @moduledoc """
  Phoenix render_errors envelope: the same `{"error": {code, message, details}}` as the public API
  (contract decision #8).
  """

  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  test "renders 404 / 500 / 413 as the API error envelope" do
    assert PromptOnWeb.ErrorJSON.render("404.json", %{}) ==
             %{error: %{code: "not_found", message: "Not Found", details: %{}}}

    assert PromptOnWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               error: %{
                 code: "internal_server_error",
                 message: "Internal Server Error",
                 details: %{}
               }
             }

    assert PromptOnWeb.ErrorJSON.render("413.json", %{}) ==
             %{
               error: %{
                 code: "payload_too_large",
                 message: "Request Entity Too Large",
                 details: %{}
               }
             }

    assert PromptOnWeb.ErrorJSON.render("400.json", %{}) ==
             %{error: %{code: "bad_request", message: "Bad Request", details: %{}}}
  end

  test "unknown API route returns the JSON envelope", %{conn: conn} do
    conn = conn |> put_req_header("accept", "application/json") |> get("/api/v1/nope")

    assert %{"error" => %{"code" => "not_found", "message" => "Not Found", "details" => %{}}} =
             json_response(conn, 404)
  end

  test "body over 5MB returns 413 envelope before authentication", %{conn: conn} do
    project = project_fixture()
    {_key, raw} = api_key_fixture(project, scopes: [:logs])
    filler = String.duplicate("x", 5_000_001)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")

    {413, _headers, body} =
      assert_error_sent(413, fn ->
        post(conn, "/api/v1/logs", ~s({"logs": [], "filler": "#{filler}"}))
      end)

    assert %{"error" => %{"code" => "payload_too_large", "details" => %{}}} = Jason.decode!(body)
  end

  test "malformed JSON body returns 400 envelope", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    {400, _headers, body} =
      assert_error_sent(400, fn -> post(conn, "/api/v1/logs", "{not json") end)

    assert %{"error" => %{"code" => "bad_request", "details" => %{}}} = Jason.decode!(body)
  end
end
