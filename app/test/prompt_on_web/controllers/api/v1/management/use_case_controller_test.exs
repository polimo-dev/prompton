defmodule PromptOnWeb.API.V1.Management.UseCaseControllerTest do
  @moduledoc """
  `/api/v1/projects/:project/use-cases`: defining use cases and their contract (input schema,
  default params), plus the detail where a coding AI sees "what is running now" in one call.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  alias PromptOn.Prompts

  setup do
    user = user_fixture()
    org = organization_for(user)
    project = project_fixture(%{user: user, organization: org, slug: "heydiary"})
    raw = cli_token_fixture(user)

    %{user: user, org: org, project: project, raw: raw, scope: scope(project)}
  end

  describe "POST /use-cases" do
    test "defines a use case and opens its default prompt", %{raw: raw, scope: scope} do
      conn =
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases", %{
          key: "diary_generation",
          name: "Diary generation",
          kind: "chat",
          description: "writes a diary from voice transcriptions",
          input_schema: [
            %{name: "transcriptions", type: "list", required: true},
            %{name: "mode", type: "string", required: true, example: "fresh"}
          ],
          default_params: %{"temperature" => 0.5}
        })

      body = json_response(conn, 201)

      assert body["key"] == "diary_generation"
      assert body["kind"] == "chat"
      assert body["description"] == "writes a diary from voice transcriptions"
      assert body["default_params"] == %{"temperature" => 0.5}

      assert [
               %{"name" => "transcriptions", "type" => "list", "required" => true},
               %{"name" => "mode", "type" => "string", "required" => true, "example" => "fresh"}
             ] = body["input_schema"]

      # A `:chat` use case is born with a `default` prompt.
      assert {:ok, use_case} = Prompts.get_use_case_by_key("diary_generation", scope)
      assert {:ok, prompts} = Prompts.list_prompts(use_case.id, scope)
      assert Enum.map(prompts, & &1.name) == ["default"]
    end

    test "name defaults to the key and kind defaults to chat", %{raw: raw} do
      body =
        json_response(
          api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases", %{
            key: "chat_response"
          }),
          201
        )

      assert body["name"] == "chat_response"
      assert body["kind"] == "chat"
    end

    test "409 with the existing use case when the key is taken", %{raw: raw, project: project} do
      existing = use_case_fixture(project, %{key: "taken"})

      conn = api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases", %{key: "taken"})

      assert %{"error" => %{"code" => "conflict", "details" => details}} =
               json_response(conn, 409)

      assert details["use_case"]["id"] == existing.id
      assert details["use_case"]["key"] == "taken"
    end

    test "400 on a missing key, a bad kind and a malformed input schema", %{raw: raw} do
      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(
                 api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases", %{name: "x"}),
                 400
               )

      assert message =~ "key is required"

      assert %{"error" => %{"code" => "invalid_request"}} =
               json_response(
                 api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases", %{
                   key: "k",
                   kind: "audio"
                 }),
                 400
               )

      assert %{"error" => %{"code" => "invalid_request", "message" => schema_message}} =
               json_response(
                 api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases", %{
                   key: "k2",
                   input_schema: ["nope"]
                 }),
                 400
               )

      assert schema_message =~ "input_schema"
    end
  end

  describe "GET /use-cases" do
    test "lists the project's live use cases", %{raw: raw, project: project} do
      _b = use_case_fixture(project, %{key: "b_second"})
      _a = use_case_fixture(project, %{key: "a_first"})

      body =
        json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases"), 200)

      assert Enum.map(body["use_cases"], & &1["key"]) == ["a_first", "b_second"]
    end
  end

  describe "GET /use-cases/:key" do
    test "carries prompts, version summaries and the live deployments" do
      hd = heydiary_project_fixture()
      hd_raw = cli_token_fixture(hd.user)

      conn =
        api_get(
          hd_raw,
          ~p"/api/v1/orgs/personal/projects/#{hd.project.slug}/use-cases/diary_generation"
        )

      body = json_response(conn, 200)

      assert body["key"] == "diary_generation"
      assert Enum.map(body["prompts"], & &1["name"]) == ["default", "ko"]

      default = Enum.find(body["prompts"], &(&1["name"] == "default"))
      assert default["version_count"] == 1
      assert [%{"number" => 1, "message" => "import from ai_tasks"}] = default["versions"]

      assert [deployment] = body["deployments"]
      assert deployment["environment"] == "production"
      assert deployment["revision"] == 1
      assert deployment["model_id"] == hd.models.sonnet.id
      assert deployment["model"] == "anthropic/claude-sonnet-4"

      assert deployment["prompt_pins"] == %{
               "default" => hd.prompt_versions.diary.id,
               "ko" => hd.prompt_versions.diary_ko.id
             }
    end

    test "404 for an unknown use case key", %{raw: raw} do
      conn = api_get(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/nope")

      assert %{"error" => %{"code" => "not_found", "details" => %{"use_case" => "nope"}}} =
               json_response(conn, 404)
    end
  end

  describe "PATCH /use-cases/:key" do
    test "changes only the fields the request carries", %{
      raw: raw,
      project: project,
      scope: scope
    } do
      use_case =
        use_case_fixture(project, %{
          key: "patchable",
          name: "Before",
          input_schema: [%{name: "a", type: :string}],
          default_params: %{"temperature" => 0.1}
        })

      body =
        json_response(
          api_patch(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/patchable", %{
            description: "now described"
          }),
          200
        )

      assert body["description"] == "now described"
      assert body["name"] == "Before"
      assert body["default_params"] == %{"temperature" => 0.1}
      assert [%{"name" => "a"}] = body["input_schema"]

      # Mixing all three in one request runs the three actions in turn.
      body =
        json_response(
          api_patch(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/patchable", %{
            name: "After",
            input_schema: [%{name: "b", type: "number", required: true}],
            default_params: %{"temperature" => 0.9, "max_tokens" => 512}
          }),
          200
        )

      assert body["name"] == "After"
      assert [%{"name" => "b", "type" => "number", "required" => true}] = body["input_schema"]
      assert body["default_params"] == %{"temperature" => 0.9, "max_tokens" => 512}

      assert {:ok, reloaded} = Prompts.get_use_case_by_key("patchable", scope)
      assert reloaded.id == use_case.id
      assert reloaded.name == "After"
      assert reloaded.description == "now described"
    end

    test "an empty patch is a no-op that still reads back the use case", %{
      raw: raw,
      project: project
    } do
      _use_case = use_case_fixture(project, %{key: "untouched", name: "Same"})

      body =
        json_response(
          api_patch(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/untouched", %{}),
          200
        )

      assert body["name"] == "Same"
    end

    test "400 when a field has the wrong shape", %{raw: raw, project: project} do
      _use_case = use_case_fixture(project, %{key: "typed"})

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(
                 api_patch(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/typed", %{
                   default_params: "hot"
                 }),
                 400
               )

      assert message =~ "default_params must be an object"
    end
  end

  test "another organization's key sees nothing here", %{project: project} do
    _use_case = use_case_fixture(project, %{key: "secret_use_case"})
    other_raw = cli_token_fixture(user_fixture())

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(
               api_get(other_raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases"),
               404
             )
  end
end
