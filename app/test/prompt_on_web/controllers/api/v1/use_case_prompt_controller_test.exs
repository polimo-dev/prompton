defmodule PromptOnWeb.API.V1.UseCasePromptControllerTest do
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  @golden "Please write a diary entry based on these voice transcriptions:\n\n1. a\n\n2. b\n\n"

  setup do
    hd = heydiary_project_fixture()
    {api_key, raw} = api_key_fixture(hd.project)
    %{hd: hd, api_key: api_key, raw: raw}
  end

  defp post_prompt(raw, key, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/use-cases/#{key}/prompt", Jason.encode!(body))
  end

  test "401 without a key / 403 without read scope", %{hd: hd} do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/use-cases/diary_generation/prompt", "{}")

    assert json_response(conn, 401)

    {_key, logs_raw} = api_key_fixture(hd.project, scopes: [:logs])
    conn = post_prompt(logs_raw, "diary_generation", %{})
    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
  end

  test "happy path with render — golden byte-identical diary template", %{hd: hd, raw: raw} do
    conn =
      post_prompt(raw, "diary_generation", %{
        prompt: "ko",
        variables: %{transcriptions: ["a", "b"], mode: "fresh"}
      })

    body = json_response(conn, 200)

    assert body["key"] == "diary_generation"
    assert body["kind"] == "chat"
    assert body["deployment"] == %{"id" => hd.deployments.diary.id, "revision" => 1}
    assert body["prompt"] == "ko"
    assert body["prompt_names"] == ["default", "ko"]
    assert body["model_id"] == hd.models.sonnet.id
    assert body["model"] == "anthropic/claude-sonnet-4"
    assert body["provider"] == "openrouter"
    assert body["source"] == "remote"
    assert body["params"] == %{"temperature" => 0.4}

    assert body["provider_options"] == %{
             "only" => ["Anthropic"],
             "allow_fallbacks" => false
           }

    assert body["prompt_version"] == %{"id" => hd.prompt_versions.diary_ko.id, "number" => 1}

    assert [
             %{
               "role" => "system",
               "content" => "You write diaries in Korean from voice transcriptions."
             },
             %{"role" => "user", "content" => @golden}
           ] = body["messages"]

    assert body["warnings"] == []
    assert String.starts_with?(body["etag"], "sha256-")
    refute Map.has_key?(body, "text")

    # Targets, rules and context are gone (deployments are pins).
    refute Map.has_key?(body, "target_id")
    refute Map.has_key?(body, "targets")

    # Without a prompt name it is the `default` pin: the default prompt's system message.
    body = json_response(post_prompt(raw, "diary_generation", %{}), 200)
    assert body["prompt"] == "default"
    assert body["prompt_version"]["id"] == hd.prompt_versions.diary.id
    assert hd(body["messages"])["content"] == "You write diaries from voice transcriptions."

    # Without variables, the raw template
    assert Enum.at(body["messages"], 1)["content"] == heydiary_diary_user_template()
  end

  test "the environment is a request parameter — the same project key reads both", %{
    hd: hd,
    raw: raw
  } do
    staging =
      deployment_fixture(hd.use_cases.chat, hd.staging, %{
        model_id: hd.models.opus.id,
        prompt_pins: %{"default" => hd.prompt_versions.chat.id}
      })

    body = json_response(post_prompt(raw, "chat_response", %{}), 200)
    assert body["model"] == "openai/gpt-5-mini"
    assert body["deployment"]["id"] == hd.deployments.chat.id

    body =
      json_response(post_prompt(raw, "chat_response", %{environment: "staging"}), 200)

    assert body["model"] == "anthropic/claude-opus-4"
    assert body["deployment"] == %{"id" => staging.id, "revision" => 1}

    # An unknown environment is 404, a non-string one is 400
    conn = post_prompt(raw, "chat_response", %{environment: "canary"})

    assert %{"error" => %{"code" => "not_found", "details" => %{"environment" => "canary"}}} =
             json_response(conn, 404)

    conn = post_prompt(raw, "chat_response", %{environment: 1})
    assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
  end

  test "an unpinned prompt name is 404 and lists the pinned names", %{raw: raw} do
    conn = post_prompt(raw, "diary_generation", %{prompt: "ja"})

    assert %{"error" => %{"code" => "not_found", "message" => message, "details" => details}} =
             json_response(conn, 404)

    assert message =~ ~s|"ja"|
    assert details["reason"] == "unknown_prompt"
    assert details["key"] == "diary_generation"
    assert details["prompt_names"] == ["default", "ko"]
  end

  test "text kind renders `text`; embedding has neither", %{hd: hd, raw: raw} do
    conn = post_prompt(raw, "voice_transcription", %{variables: %{}})
    body = json_response(conn, 200)
    assert body["kind"] == "text"
    assert body["text"] == "diary, day, today's mood"
    assert body["provider"] == "groq"
    refute Map.has_key?(body, "messages")

    conn = post_prompt(raw, "diary_embedding", %{})
    body = json_response(conn, 200)
    assert body["kind"] == "embedding"
    assert body["model_id"] == hd.models.embed.id
    assert body["prompt"] == nil
    assert body["prompt_names"] == []
    assert body["prompt_version"] == nil
    refute Map.has_key?(body, "messages")
    refute Map.has_key?(body, "text")
  end

  test "errors: unknown 404, unresolved 404, missing variable 400",
       %{hd: hd, raw: raw} do
    conn = post_prompt(raw, "nope", %{})
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    # No live Deployment → unresolved
    _ = use_case_fixture(hd.project, %{key: "mood_inference"})
    conn = post_prompt(raw, "mood_inference", %{})

    assert %{"error" => %{"code" => "not_found", "details" => %{"reason" => "unresolved"}}} =
             json_response(conn, 404)

    conn = post_prompt(raw, "diary_generation", %{variables: %{mode: "fresh"}})

    assert %{
             "error" => %{
               "code" => "invalid_request",
               "details" => %{"missing_variable" => "transcriptions"}
             }
           } = json_response(conn, 400)
  end

  test "malformed input shapes are 400 invalid_request, never 500", %{raw: raw} do
    # variables must be an object
    conn = post_prompt(raw, "diary_generation", %{variables: "mode=fresh"})

    assert %{"error" => %{"code" => "invalid_request", "message" => msg}} =
             json_response(conn, 400)

    assert msg =~ "variables"

    # prompt must be a non-empty string
    for bad <- [42, "", ["ko"]] do
      conn = post_prompt(raw, "diary_generation", %{prompt: bad})

      assert %{"error" => %{"code" => "invalid_request", "message" => msg}} =
               json_response(conn, 400)

      assert msg =~ "prompt"
    end
  end

  test "the resolved prompt version is the one the live revision pins", %{hd: hd, raw: raw} do
    body = json_response(post_prompt(raw, "diary_generation", %{prompt: "ko"}), 200)
    pinned = Map.values(hd.deployments.diary.prompt_pins)

    assert body["prompt_version"]["id"] in pinned
    assert body["prompt_version"]["id"] == hd.deployments.diary.prompt_pins["ko"]
  end

  test "an environment with no deployment resolves nothing", %{raw: raw} do
    conn = post_prompt(raw, "diary_generation", %{environment: "staging"})

    assert %{"error" => %{"code" => "not_found", "details" => %{"reason" => "unresolved"}}} =
             json_response(conn, 404)
  end
end
