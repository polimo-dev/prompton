defmodule PromptOnWeb.API.V1.Management.ApiKeyControllerTest do
  @moduledoc """
  Runtime key issuance, the last step of onboarding. Checks that **the raw key leaves only once, in
  the issuance response**, and that the key cannot open the management API (layer separation).
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  alias PromptOn.Projects

  setup do
    user = user_fixture()
    org = organization_for(user)
    project = project_fixture(%{user: user, organization: org, slug: "heydiary"})
    raw = cli_token_fixture(user)

    %{project: project, raw: raw}
  end

  test "issues a runtime key and returns the raw value once", %{raw: raw, project: project} do
    conn =
      api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys", %{
        name: "HeyDiary server"
      })

    body = json_response(conn, 201)

    assert body["name"] == "HeyDiary server"
    assert body["scopes"] == ["read", "logs"]
    assert String.starts_with?(body["key"], "ptn_heydiary_")
    assert body["key_prefix"] == String.slice(body["key"], 0, 16)

    assert {:ok, [issued]} = Projects.list_api_keys(project.id, actor: system_actor())
    assert issued.id == body["id"]

    # The listing carries no raw key.
    listed =
      json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys"), 200)

    assert [key] = listed["api_keys"]
    refute Map.has_key?(key, "key")
    assert key["key_prefix"] == body["key_prefix"]
  end

  test "the name defaults and scopes can be narrowed", %{raw: raw} do
    body =
      json_response(api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys", %{}), 201)

    assert body["name"] == "CLI key"

    body =
      json_response(
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys", %{
          name: "logs only",
          scopes: ["logs"]
        }),
        201
      )

    assert body["scopes"] == ["logs"]
  end

  test "400 on an unknown scope and a malformed scopes list", %{raw: raw} do
    assert %{"error" => %{"code" => "invalid_request"}} =
             json_response(
               api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys", %{
                 scopes: ["admin"]
               }),
               400
             )

    assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
             json_response(
               api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys", %{
                 scopes: "logs"
               }),
               400
             )

    assert message =~ "scopes"
  end

  test "the issued runtime key opens the public API but not this one", %{
    raw: raw,
    project: project
  } do
    use_case = use_case_fixture(project, %{key: "chat_response", kind: :chat})
    _deployment = simple_deployment_fixture(use_case, environment(project, "production"))

    body =
      json_response(api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys", %{}), 201)

    runtime_raw = body["key"]

    resolved =
      build_conn()
      |> put_req_header("authorization", "Bearer #{runtime_raw}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/use-cases/chat_response/prompt", Jason.encode!(%{}))
      |> json_response(200)

    assert resolved["key"] == "chat_response"

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(api_get(runtime_raw, ~p"/api/v1/orgs/personal/projects"), 401)
  end

  test "revoked keys drop out of the listing", %{raw: raw, project: project} do
    {key, _raw} = api_key_fixture(project)
    {:ok, _revoked} = Projects.revoke_api_key(key, actor: system_actor())

    assert json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys"), 200) ==
             %{
               "api_keys" => []
             }
  end

  test "another organization's key cannot issue here" do
    other_raw = cli_token_fixture(user_fixture())

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(
               api_post(other_raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys", %{}),
               404
             )
  end
end
