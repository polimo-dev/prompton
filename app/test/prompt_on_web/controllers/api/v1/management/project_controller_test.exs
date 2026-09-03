defmodule PromptOnWeb.API.V1.Management.ProjectControllerTest do
  @moduledoc """
  `/api/v1/projects`: the first step of provisioning. The two axes of this file are the organization
  boundary (another organization's project **does not exist**) and idempotency (creating again with
  the same key is a 409 plus that project).
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  alias PromptOn.Projects

  setup do
    user = user_fixture()
    org = organization_for(user)
    raw = cli_token_fixture(user)

    other_user = user_fixture()
    other_org = organization_for(other_user)
    other_raw = cli_token_fixture(other_user)

    %{
      user: user,
      org: org,
      raw: raw,
      other_user: other_user,
      other_org: other_org,
      other_raw: other_raw
    }
  end

  describe "POST /projects" do
    test "creates a project with the default environments", %{raw: raw, org: org} do
      conn =
        api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "heydiary", name: "HeyDiary"})

      body = json_response(conn, 201)

      assert body["slug"] == "heydiary"
      assert body["name"] == "HeyDiary"
      assert body["timezone"] == "Etc/UTC"
      assert Enum.map(body["environments"], & &1["slug"]) == ["production", "staging"]
      assert Enum.find(body["environments"], &(&1["slug"] == "production"))["protected"] == true

      assert {:ok, project} =
               Projects.get_project_by_slug(org.id, "heydiary", actor: system_actor())

      assert project.id == body["id"]
      assert project.organization_id == org.id
    end

    test "name defaults to the key, and slug is accepted as an alias", %{raw: raw} do
      body = json_response(api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "solo"}), 201)
      assert body["name"] == "solo"

      body =
        json_response(api_post(raw, ~p"/api/v1/orgs/personal/projects", %{slug: "aliased"}), 201)

      assert body["slug"] == "aliased"
    end

    test "409 with the existing project when the key is taken", %{raw: raw} do
      created =
        json_response(api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "twice"}), 201)

      conn = api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "twice", name: "Another"})

      assert %{"error" => %{"code" => "conflict", "message" => message, "details" => details}} =
               json_response(conn, 409)

      assert message =~ "twice"
      assert details["project"]["id"] == created["id"]
      assert details["project"]["slug"] == "twice"
    end

    test "400 without a key, and on reserved or malformed slugs", %{raw: raw} do
      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(
                 api_post(raw, ~p"/api/v1/orgs/personal/projects", %{name: "no key"}),
                 400
               )

      assert message =~ "key is required"

      assert %{"error" => %{"code" => "invalid_request"}} =
               json_response(
                 api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "settings"}),
                 400
               )

      assert %{"error" => %{"code" => "invalid_request"}} =
               json_response(
                 api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "Not A Slug"}),
                 400
               )
    end

    test "two organizations may use the same project key", %{raw: raw, other_raw: other_raw} do
      assert json_response(
               api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "shared"}),
               201
             )

      assert json_response(
               api_post(other_raw, ~p"/api/v1/orgs/personal/projects", %{key: "shared"}),
               201
             )
    end
  end

  describe "GET /projects" do
    test "lists only this organization's projects", %{
      raw: raw,
      other_raw: other_raw,
      user: user,
      org: org
    } do
      mine = project_fixture(%{user: user, organization: org, slug: "mine"})
      _theirs = project_fixture(%{slug: "theirs"})

      body = json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects"), 200)

      assert Enum.map(body["projects"], & &1["slug"]) == ["mine"]
      assert hd(body["projects"])["id"] == mine.id

      assert json_response(api_get(other_raw, ~p"/api/v1/orgs/personal/projects"), 200) == %{
               "projects" => []
             }
    end

    test "archived projects drop out of the listing", %{raw: raw, user: user, org: org} do
      project = project_fixture(%{user: user, organization: org, slug: "gone"})
      {:ok, _archived} = Projects.archive_project(project, actor: system_actor())

      assert json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects"), 200) == %{
               "projects" => []
             }
    end
  end

  describe "project addressing" do
    test "another organization's project is 404, not 403", %{
      other_raw: other_raw,
      user: user,
      org: org
    } do
      _mine = project_fixture(%{user: user, organization: org, slug: "private"})

      conn = api_get(other_raw, ~p"/api/v1/orgs/personal/projects/private/use-cases")

      assert %{"error" => %{"code" => "not_found", "details" => %{"project" => "private"}}} =
               json_response(conn, 404)
    end

    test "an archived project is 404 too", %{raw: raw, user: user, org: org} do
      project = project_fixture(%{user: user, organization: org, slug: "retired"})
      {:ok, _archived} = Projects.archive_project(project, actor: system_actor())

      assert %{"error" => %{"code" => "not_found"}} =
               json_response(
                 api_get(raw, ~p"/api/v1/orgs/personal/projects/retired/use-cases"),
                 404
               )
    end

    test "401 after the CLI session is revoked", %{raw: raw} do
      :ok = PromptOn.Accounts.CliSession.revoke(raw)

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects"), 401)
    end
  end
end
