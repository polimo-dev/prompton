defmodule PromptOnWeb.API.V1.Management.SessionControllerTest do
  @moduledoc """
  `GET /api/v1/me` and `POST /api/v1/sessions/revoke`: the CLI session itself.

  `/me` is what `prompton login` calls right after signing in and what `whoami` calls; revoke is
  `prompton logout`.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts.CliSession

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  describe "GET /me" do
    test "answers with the user and every organization they can provision" do
      user = user_fixture()
      personal = organization_for(user)
      team = team_org_fixture(%{user: user, slug: "acme-me"})

      body = json_response(api_get(cli_token_fixture(user), ~p"/api/v1/me"), 200)

      assert body["user"] == %{"id" => user.id, "email" => to_string(user.email)}
      assert Enum.map(body["organizations"], & &1["id"]) == [personal.id, team.id]
    end

    test "401 without a token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> get(~p"/api/v1/me")

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end
  end

  describe "last use" do
    test "an authenticated call stamps the session's last_used_at" do
      user = user_fixture()
      token = cli_token_fixture(user)
      assert [%CliSession{last_used_at: nil}] = CliSession.list(user)

      assert json_response(api_get(token, ~p"/api/v1/me"), 200)

      assert [%CliSession{last_used_at: %DateTime{}}] = CliSession.list(user)
    end
  end

  describe "POST /sessions/revoke" do
    test "revokes this token and nothing else" do
      user = user_fixture()
      one = cli_token_fixture(user)
      two = cli_token_fixture(user)

      assert json_response(api_post(one, ~p"/api/v1/sessions/revoke"), 200) == %{
               "revoked" => true
             }

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(api_get(one, ~p"/api/v1/me"), 401)

      # Sessions on other machines stay alive; cleaning up one laptop does not cut off the rest.
      assert json_response(api_get(two, ~p"/api/v1/me"), 200)["user"]["id"] == user.id
    end

    test "revoking twice is still 401 on the second call (the token is already gone)" do
      raw = cli_token_fixture(user_fixture())

      assert json_response(api_post(raw, ~p"/api/v1/sessions/revoke"), 200)

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(api_post(raw, ~p"/api/v1/sessions/revoke"), 401)
    end
  end
end
