defmodule PromptOnWeb.API.V1.Management.ProvisioningJourneyTest do
  @moduledoc """
  **Walks the whole onboarding of agent-first-spec §3 over HTTP in one go.**

  It starts at `prompton login`: what the coding AI ends up holding is not a key but a **CLI session
  token that a human approved in the browser**:

      device/code → (human approves) → device/token → /me
      → create project → define use case → prompts (default, ko) + commit versions
      → register model → commit deployment pins → issue runtime API key
      → **with that key, `POST /api/v1/resolve` actually answers**

  The last line is why this test exists: provisioning ends at "the app can fetch its config", not at
  "rows were created". It then continues with the same token through staging promotion (§4),
  rollback and BYOK registration (§3.7).

  Only the single approval (the human's screen) is done through the domain; everything else is
  **HTTP**. This path is exactly what the CLI (batch ③) and the landing page's master prompt
  (batch ④) will see.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  alias PromptOn.Accounts
  alias PromptOn.Accounts.CliSession

  @diary_system "You write diaries from voice transcriptions."
  @diary_user "Write a diary from:\n\n{% for t in transcriptions %}{{ forloop.index }}. {{ t }}\n{% endfor %}"
  @ko_system "You write diaries in Korean from voice transcriptions."

  setup do
    user = user_fixture()
    org = organization_for(user)

    %{user: user, org: org}
  end

  test "a coding AI logs in, provisions a project end to end and the app fetches its config", %{
    user: user,
    org: org
  } do
    # 0. `prompton login`: device authorization ------------------------------------
    codes =
      json_response(
        post(
          json_conn(),
          ~p"/api/v1/device/code",
          Jason.encode!(%{client: "prompton-cli/0.1.0 (darwin/arm64)", name: "CLI on lain"})
        ),
        201
      )

    # Before approval, it waits.
    assert %{"error" => %{"code" => "authorization_pending"}} =
             json_response(poll(codes["device_code"]), 400)

    # A human approves in the browser (`/device`); that screen is tested in `DeviceLiveTest`.
    approve(codes["user_code"], user)

    # Polling is a 5-second-interval contract; instead of waiting on the clock, the test pushes the
    # last polled time back.
    wait(codes["user_code"])
    session = json_response(poll(codes["device_code"]), 200)

    raw = session["token"]
    assert session["user"]["email"] == to_string(user.email)
    assert Enum.map(session["organizations"], & &1["id"]) == [org.id]

    # The token comes out only once.
    wait(codes["user_code"])

    assert %{"error" => %{"code" => "expired_token"}} =
             json_response(poll(codes["device_code"]), 400)

    # 1. Where to create it ----------------------------------------------------
    me = json_response(api_get(raw, ~p"/api/v1/me"), 200)
    assert me["user"]["id"] == user.id
    assert Enum.map(me["organizations"], & &1["slug"]) == [nil]

    who = json_response(api_get(raw, ~p"/api/v1/orgs/personal"), 200)
    assert who["id"] == org.id

    assert json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects"), 200) == %{
             "projects" => []
           }

    # 2. Project -------------------------------------------------------------
    project =
      json_response(
        api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "heydiary", name: "HeyDiary"}),
        201
      )

    assert Enum.map(project["environments"], & &1["slug"]) == ["production", "staging"]

    # 3. Use case ------------------------------------------------------------
    use_case =
      json_response(
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases", %{
          key: "diary_generation",
          name: "Diary generation",
          kind: "chat",
          input_schema: [%{name: "transcriptions", type: "list", required: true}],
          default_params: %{"temperature" => 0.5}
        }),
        201
      )

    assert use_case["key"] == "diary_generation"

    # 4. Prompts + versions (two names, one per language) -----------------------
    default_v1 =
      json_response(
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/default/versions",
          %{
            messages: [
              %{role: "system", content: @diary_system},
              %{role: "user", content: @diary_user}
            ],
            message: "migrated from the app's hardcoded prompt"
          }
        ),
        201
      )

    assert default_v1["number"] == 1
    assert default_v1["detected_variables"] == ["transcriptions"]

    assert json_response(
             api_post(
               raw,
               ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts",
               %{
                 name: "ko",
                 description: "Korean"
               }
             ),
             201
           )["name"] == "ko"

    ko_v1 =
      json_response(
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/ko/versions",
          %{
            messages: [
              %{role: "system", content: @ko_system},
              %{role: "user", content: @diary_user}
            ]
          }
        ),
        201
      )

    # 5. Model ---------------------------------------------------------------
    model =
      json_response(
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models", %{
          model_id: "anthropic/claude-sonnet-4",
          display_name: "Claude Sonnet 4",
          provider_options: %{"only" => ["Anthropic"]}
        }),
        201
      )

    assert json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models"), 200)[
             "models"
           ]
           |> Enum.map(& &1["model_id"]) == ["anthropic/claude-sonnet-4"]

    # 6. Deployment pins (omitting the pins means every latest committed version) ----
    deployment =
      json_response(
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/deployments",
          %{
            model_id: model["id"],
            params: %{"temperature" => 0.4}
          }
        ),
        201
      )

    assert deployment["revision"] == 1
    assert deployment["environment"] == "production"

    assert deployment["prompt_pins"] == %{
             "default" => default_v1["id"],
             "ko" => ko_v1["id"]
           }

    # 7. Runtime key ---------------------------------------------------------
    issued =
      json_response(
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/api-keys", %{
          name: "HeyDiary server"
        }),
        201
      )

    runtime_key = issued["key"]
    assert String.starts_with?(runtime_key, "ptn_heydiary_")

    # 8. **The app fetches its config**: onboarding is done only once we get here. ----
    resolved =
      runtime_key
      |> runtime_conn()
      |> post(
        ~p"/api/v1/resolve",
        Jason.encode!(%{
          use_case: "diary_generation",
          prompt: "ko",
          variables: %{"transcriptions" => ["a", "b"]}
        })
      )
      |> json_response(200)

    assert resolved["deployment"] == %{"id" => deployment["id"], "revision" => 1}
    assert resolved["model"] == "anthropic/claude-sonnet-4"
    assert resolved["prompts"] == ["default", "ko"]
    assert resolved["effective_params"] == %{"temperature" => 0.4}
    assert resolved["effective_provider_options"] == %{"only" => ["Anthropic"]}
    assert [%{"content" => @ko_system}, %{"content" => rendered}] = resolved["messages"]
    assert rendered == "Write a diary from:\n\n1. a\n2. b\n"

    snapshot =
      runtime_key
      |> runtime_conn()
      |> get(~p"/api/v1/snapshot?environment=production")
      |> json_response(200)

    assert snapshot["schema_version"] == 3
    assert snapshot["project"] == "heydiary"
    assert Map.keys(snapshot["deployments"]) == ["diary_generation"]

    # 9. New version → staging promotion → production commit → rollback (§4) ---------
    default_v2 =
      json_response(
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/prompts/default/versions",
          %{
            messages: [
              %{role: "system", content: "You write short diaries."},
              %{role: "user", content: @diary_user}
            ],
            message: "shorter"
          }
        ),
        201
      )

    assert default_v2["number"] == 2

    staging =
      json_response(
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/deployments",
          %{
            environment: "staging",
            model: "anthropic/claude-sonnet-4",
            prompt_pins: %{"default" => default_v2["id"]}
          }
        ),
        201
      )

    assert staging["environment"] == "staging"
    assert staging["model_id"] == model["id"]

    production_v2 =
      json_response(
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/deployments",
          %{
            model_id: model["id"],
            prompt_pins: %{"default" => default_v2["id"], "ko" => ko_v1["id"]},
            params: %{"temperature" => 0.4}
          }
        ),
        201
      )

    assert production_v2["revision"] == 2

    rolled_back =
      json_response(
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/deployments/rollback",
          %{revision: 1}
        ),
        200
      )

    assert rolled_back["revision"] == 3
    assert rolled_back["prompt_pins"] == deployment["prompt_pins"]

    # 10. The detail shows "what is running now" in one call ----------------------
    detail =
      json_response(
        api_get(raw, ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation"),
        200
      )

    assert Enum.map(detail["prompts"], & &1["name"]) == ["default", "ko"]
    assert Enum.find(detail["prompts"], &(&1["name"] == "default"))["version_count"] == 2

    assert Enum.map(detail["deployments"], &{&1["environment"], &1["revision"]}) == [
             {"production", 3},
             {"staging", 1}
           ]

    # 11. BYOK is an option after onboarding (§3.7) ------------------------------
    assert json_response(api_get(raw, ~p"/api/v1/orgs/personal/provider-key"), 200)["connected"] ==
             false

    assert json_response(
             api_post(raw, ~p"/api/v1/orgs/personal/provider-key", %{
               secret: "sk-or-v1-0123456789abcdef0123456789abcdef4Xa2"
             }),
             201
           )["hint"] == "sk-or-v1-••••4Xa2"

    assert json_response(api_get(raw, ~p"/api/v1/orgs/personal/provider-key"), 200)["connected"] ==
             true

    # 12. Re-running the script does not get stuck; the 409 returns what is already there.
    assert %{"error" => %{"code" => "conflict", "details" => details}} =
             json_response(
               api_post(raw, ~p"/api/v1/orgs/personal/projects", %{key: "heydiary"}),
               409
             )

    assert details["project"]["id"] == project["id"]

    # 13. `prompton logout`: revokes only this session. ---------------------------
    assert json_response(api_post(raw, ~p"/api/v1/sessions/revoke"), 200) == %{"revoked" => true}

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects"), 401)

    # The app's runtime key is still alive; a human's logout does not cut off the service.
    assert runtime_key
           |> runtime_conn()
           |> get(~p"/api/v1/snapshot?environment=production")
           |> json_response(200)
  end

  # What the `/device` screen does: when a human approves, that person's CLI session token is
  # minted and attached to the request.
  defp approve(user_code, user) do
    {:ok, request} = Accounts.device_authorization_by_user_code(user_code, actor: user)
    {:ok, token, _claims} = CliSession.issue(user)

    {:ok, _approved} =
      Accounts.approve_device_authorization(request, %{user_id: user.id, token: token},
        actor: user
      )

    :ok
  end

  defp poll(device_code),
    do: post(json_conn(), ~p"/api/v1/device/token", Jason.encode!(%{device_code: device_code}))

  # Lets the next poll happen without producing `slow_down`, without actually waiting 5 seconds.
  defp wait(user_code) do
    at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_naive()

    PromptOn.Repo.query!(
      "UPDATE device_authorizations SET last_polled_at = $1 WHERE user_code = $2",
      [at, user_code]
    )

    :ok
  end

  defp json_conn, do: put_req_header(build_conn(), "content-type", "application/json")

  defp runtime_conn(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end
end
