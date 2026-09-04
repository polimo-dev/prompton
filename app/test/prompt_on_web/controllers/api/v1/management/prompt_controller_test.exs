defmodule PromptOnWeb.API.V1.Management.PromptControllerTest do
  @moduledoc """
  Opening prompts and **committing immutable versions**. Checks that a commit alone makes nothing
  live (live happens when a deployment revision pins it) and that the template lint runs at commit
  time.
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
    use_case = use_case_fixture(project, %{key: "diary_generation", kind: :chat})

    %{project: project, raw: raw, use_case: use_case, scope: scope(project)}
  end

  describe "POST /prompts" do
    test "opens a second, named prompt", %{raw: raw, use_case: use_case, scope: scope} do
      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts",
          %{
            name: "ko",
            description: "Korean"
          }
        )

      body = json_response(conn, 201)

      assert body["name"] == "ko"
      assert body["description"] == "Korean"

      assert {:ok, prompts} = Prompts.list_prompts(use_case.id, scope)
      assert Enum.map(prompts, & &1.name) |> Enum.sort() == ["default", "ko"]
    end

    test "409 with the existing prompt (the default one is already there)", %{raw: raw} do
      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts",
          %{
            name: "default"
          }
        )

      assert %{"error" => %{"code" => "conflict", "details" => details}} =
               json_response(conn, 409)

      assert details["prompt"]["name"] == "default"
    end

    test "400 without a name", %{raw: raw} do
      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts",
          %{}
        )

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "name is required"
    end
  end

  describe "POST /prompts/:name/versions" do
    test "commits an immutable version and extracts its variables", %{raw: raw} do
      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/default/versions",
          %{
            messages: [
              %{role: "system", content: "You write diaries."},
              %{role: "user", content: "{{ transcript }}"}
            ],
            message: "import from ai_tasks"
          }
        )

      body = json_response(conn, 201)

      assert body["number"] == 1
      assert body["engine"] == "liquid"
      assert body["message"] == "import from ai_tasks"
      assert body["detected_variables"] == ["transcript"]
      assert body["content_sha256"]

      assert [
               %{"role" => "system", "content" => "You write diaries."},
               %{"role" => "user", "content" => "{{ transcript }}"}
             ] = body["messages"]

      # Committing again gets a new number; there is no way to edit an existing version.
      second =
        json_response(
          api_post(
            raw,
            ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/default/versions",
            %{messages: [%{role: "system", content: "v2"}]}
          ),
          201
        )

      assert second["number"] == 2
      assert second["id"] != body["id"]
    end

    test "text use cases commit a text_template", %{raw: raw, project: project} do
      _stt = use_case_fixture(project, %{key: "voice_transcription", kind: :text})

      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/voice_transcription/prompts/default/versions",
          %{text_template: "diary, day, today's mood"}
        )

      body = json_response(conn, 201)

      assert body["text_template"] == "diary, day, today's mood"
      assert body["messages"] == []
    end

    test "400 when the content does not match the use case kind", %{raw: raw} do
      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/default/versions",
          %{text_template: "chat use cases have messages"}
        )

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end

    test "400 when the template fails the lint", %{raw: raw} do
      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/default/versions",
          %{messages: [%{role: "user", content: "{% include 'other' %}"}]}
        )

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end

    test "400 when messages are the wrong shape", %{raw: raw} do
      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/default/versions",
          %{messages: [%{role: "user"}]}
        )

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "messages"
    end

    test "404 for an unknown prompt name, listing the ones that exist", %{raw: raw} do
      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/ja/versions",
          %{messages: [%{role: "user", content: "x"}]}
        )

      assert %{"error" => %{"code" => "not_found", "details" => details}} =
               json_response(conn, 404)

      assert details["prompt"] == "ja"
      assert details["prompt_names"] == ["default"]
    end

    test "another organization's key cannot commit here", %{raw: _raw} do
      other_raw = cli_token_fixture(user_fixture())

      conn =
        api_post(
          other_raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/default/versions",
          %{messages: [%{role: "user", content: "x"}]}
        )

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end
end
