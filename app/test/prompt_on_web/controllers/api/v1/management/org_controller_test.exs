defmodule PromptOnWeb.API.V1.Management.OrgControllerTest do
  @moduledoc """
  `GET /api/v1/orgs` and `GET /api/v1/orgs/:org`: where the CLI picks "where to provision".

  With management keys gone (2026-09-02) the credential is no longer tied to a single organization,
  so what is checked here is the **list**, and the organization boundary is set by the `:org`
  segment of the path. Someone else's organization is a 404, not a 403.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  describe "GET /orgs" do
    test "lists the organizations this user belongs to, personal first" do
      user = user_fixture()
      personal = organization_for(user)
      team = team_org_fixture(%{user: user, slug: "acme-inc", name: "Acme"})

      body = json_response(api_get(cli_token_fixture(user), ~p"/api/v1/orgs"), 200)

      assert Enum.map(body["organizations"], & &1["id"]) == [personal.id, team.id]

      assert [%{"personal" => true, "slug" => nil}, %{"personal" => false, "slug" => "acme-inc"}] =
               body["organizations"]
    end

    test "another user's organizations are not in the list" do
      stranger = user_fixture()
      _theirs = team_org_fixture(%{user: stranger, slug: "not-mine"})

      body = json_response(api_get(cli_token_fixture(user_fixture()), ~p"/api/v1/orgs"), 200)

      assert Enum.map(body["organizations"], & &1["slug"]) == [nil]
    end
  end

  describe "GET /orgs/:org" do
    test "`personal` resolves to this user's personal organization" do
      user = user_fixture()
      org = organization_for(user)

      body = json_response(api_get(cli_token_fixture(user), ~p"/api/v1/orgs/personal"), 200)

      assert body["id"] == org.id
      assert body["personal"] == true
      assert body["slug"] == nil
      assert body["created_at"]
    end

    test "a team organization is addressed by slug" do
      user = user_fixture()
      org = team_org_fixture(%{user: user, slug: "acme-inc", name: "Acme"})

      body = json_response(api_get(cli_token_fixture(user), ~p"/api/v1/orgs/acme-inc"), 200)

      assert body["id"] == org.id
      assert body["slug"] == "acme-inc"
      assert body["personal"] == false
    end

    test "a team organization a member joined later is reachable too" do
      owner = user_fixture()
      org = team_org_fixture(%{user: owner, slug: "acme-two"})
      member = user_fixture()

      {:ok, _membership} =
        PromptOn.Accounts.add_member(
          %{organization_id: org.id, user_id: member.id, role: :editor},
          actor: system_actor()
        )

      assert json_response(api_get(cli_token_fixture(member), ~p"/api/v1/orgs/acme-two"), 200)[
               "id"
             ] ==
               org.id
    end

    test "a non-member gets 404, not 403" do
      owner = user_fixture()
      _org = team_org_fixture(%{user: owner, slug: "acme-secret"})

      conn = api_get(cli_token_fixture(user_fixture()), ~p"/api/v1/orgs/acme-secret")

      assert %{
               "error" => %{
                 "code" => "not_found",
                 "details" => %{"organization" => "acme-secret"}
               }
             } = json_response(conn, 404)
    end

    test "an organization that does not exist is the same 404" do
      conn = api_get(cli_token_fixture(user_fixture()), ~p"/api/v1/orgs/nobody-here")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "the two layers do not open each other's doors" do
    test "401 without a token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> get(~p"/api/v1/orgs")

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "a runtime project key cannot open the management API" do
      project = project_fixture()
      {_key, runtime_raw} = api_key_fixture(project)

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(api_get(runtime_raw, ~p"/api/v1/orgs"), 401)
    end

    test "a CLI session token cannot open the runtime API" do
      user = user_fixture()

      conn =
        user
        |> cli_token_fixture()
        |> conn()
        |> get(~p"/api/v1/snapshot")

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end
  end
end
