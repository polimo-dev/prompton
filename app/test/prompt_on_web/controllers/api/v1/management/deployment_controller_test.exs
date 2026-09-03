defmodule PromptOnWeb.API.V1.Management.DeploymentControllerTest do
  @moduledoc """
  Deployment **pins**: live the moment they are committed, and a rollback is committing a new
  revision with the pins of a past revision. Also covers the path where a `model` string registers
  the catalog entry in the same step, and the default that pins "every latest committed version"
  when the pins are omitted.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  alias PromptOn.Catalog
  alias PromptOn.Deployments

  @path "/api/v1/orgs/personal/projects/heydiary/use-cases/diary_generation/deployments"

  setup do
    user = user_fixture()
    org = organization_for(user)
    project = project_fixture(%{user: user, organization: org, slug: "heydiary"})
    raw = cli_token_fixture(user)

    use_case = use_case_fixture(project, %{key: "diary_generation", kind: :chat})
    version = prompt_version_fixture(use_case)
    model = model_fixture(project, %{model_id: "anthropic/claude-sonnet-4"})

    %{
      project: project,
      raw: raw,
      use_case: use_case,
      version: version,
      model: model,
      scope: scope(project),
      production: environment(project, "production"),
      staging: environment(project, "staging")
    }
  end

  describe "POST /deployments" do
    test "pins the latest committed version of every prompt by default", %{
      raw: raw,
      model: model,
      version: version
    } do
      body = json_response(api_post(raw, @path, %{model_id: model.id}), 201)

      assert body["revision"] == 1
      assert body["environment"] == "production"
      assert body["model_id"] == model.id
      assert body["model"] == "anthropic/claude-sonnet-4"
      assert body["prompt_pins"] == %{"default" => version.id}
      assert body["params"] == %{}
    end

    test "registers the model on the fly when given a provider string", %{raw: raw, scope: scope} do
      body = json_response(api_post(raw, @path, %{model: "openai/gpt-5-mini"}), 201)

      assert {:ok, model} =
               Catalog.get_model_by_provider_model(:openrouter, "openai/gpt-5-mini", scope)

      assert body["model_id"] == model.id
      assert body["model"] == "openai/gpt-5-mini"

      # The second commit reuses the same catalog entry (no duplicate registration is created).
      second = json_response(api_post(raw, @path, %{model: "openai/gpt-5-mini"}), 201)
      assert second["model_id"] == model.id
      assert second["revision"] == 2
    end

    test "takes explicit pins, params, provider options and an environment", %{
      raw: raw,
      model: model,
      version: version
    } do
      body =
        json_response(
          api_post(raw, @path, %{
            environment: "staging",
            model_id: model.id,
            prompt_pins: %{"default" => version.id},
            params: %{"temperature" => 0.4},
            provider_options: %{"allow_fallbacks" => false}
          }),
          201
        )

      assert body["environment"] == "staging"
      assert body["revision"] == 1
      assert body["params"] == %{"temperature" => 0.4}
      assert body["provider_options"] == %{"allow_fallbacks" => false}
    end

    test "400 without a model", %{raw: raw} do
      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(api_post(raw, @path, %{}), 400)

      assert message =~ "model_id"
    end

    test "404 for an unknown catalog model id and an unknown environment", %{
      raw: raw,
      model: model
    } do
      assert %{"error" => %{"code" => "not_found", "details" => %{"model_id" => _}}} =
               json_response(api_post(raw, @path, %{model_id: Ash.UUIDv7.generate()}), 404)

      assert %{"error" => %{"code" => "not_found", "details" => %{"environment" => "canary"}}} =
               json_response(
                 api_post(raw, @path, %{model_id: model.id, environment: "canary"}),
                 404
               )
    end

    test "400 when there is no committed version to pin", %{
      raw: raw,
      project: project,
      model: model
    } do
      _fresh = use_case_fixture(project, %{key: "unpinned", kind: :chat})

      conn =
        api_post(
          raw,
          ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/unpinned/deployments",
          %{
            model_id: model.id
          }
        )

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "no committed prompt version"
    end

    test "400 when a pin names a prompt that does not exist", %{
      raw: raw,
      model: model,
      version: version
    } do
      conn = api_post(raw, @path, %{model_id: model.id, prompt_pins: %{"ja" => version.id}})

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end

    test "400 when prompt_pins is not an object of strings", %{raw: raw, model: model} do
      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(
                 api_post(raw, @path, %{model_id: model.id, prompt_pins: %{"default" => 1}}),
                 400
               )

      assert message =~ "prompt_pins"
    end

    test "embedding use cases pin nothing", %{raw: raw, project: project, model: model} do
      _embedding = use_case_fixture(project, %{key: "diary_embedding", kind: :embedding})

      body =
        json_response(
          api_post(
            raw,
            ~p"/api/v1/orgs/personal/projects/heydiary/use-cases/diary_embedding/deployments",
            %{
              model_id: model.id
            }
          ),
          201
        )

      assert body["prompt_pins"] == %{}
    end
  end

  describe "GET /deployments" do
    test "without an environment it lists the live revision of each environment", %{
      raw: raw,
      use_case: use_case,
      model: model,
      version: version,
      production: production,
      staging: staging
    } do
      pins = %{"default" => version.id}
      _p1 = deployment_fixture(use_case, production, %{model_id: model.id, prompt_pins: pins})
      p2 = deployment_fixture(use_case, production, %{model_id: model.id, prompt_pins: pins})
      s1 = deployment_fixture(use_case, staging, %{model_id: model.id, prompt_pins: pins})

      body = json_response(api_get(raw, @path), 200)

      assert Enum.map(body["deployments"], & &1["environment"]) == ["production", "staging"]
      assert Enum.map(body["deployments"], & &1["id"]) == [p2.id, s1.id]
      assert Enum.map(body["deployments"], & &1["revision"]) == [2, 1]
    end

    test "with an environment it lists that environment's revisions, newest first", %{
      raw: raw,
      use_case: use_case,
      model: model,
      version: version,
      production: production
    } do
      pins = %{"default" => version.id}
      _r1 = deployment_fixture(use_case, production, %{model_id: model.id, prompt_pins: pins})
      _r2 = deployment_fixture(use_case, production, %{model_id: model.id, prompt_pins: pins})

      body = json_response(api_get(raw, @path <> "?environment=production"), 200)
      assert Enum.map(body["deployments"], & &1["revision"]) == [2, 1]

      body = json_response(api_get(raw, @path <> "?environment=staging"), 200)
      assert body["deployments"] == []
    end
  end

  describe "POST /deployments/rollback" do
    setup %{
      use_case: use_case,
      model: model,
      version: version,
      production: production,
      project: project
    } do
      other_model = model_fixture(project, %{model_id: "openai/gpt-5-mini"})
      pins = %{"default" => version.id}

      first = deployment_fixture(use_case, production, %{model_id: model.id, prompt_pins: pins})

      second =
        deployment_fixture(use_case, production, %{model_id: other_model.id, prompt_pins: pins})

      %{first: first, second: second, other_model: other_model}
    end

    test "re-commits a past revision as a new one", %{
      raw: raw,
      model: model,
      second: second,
      use_case: use_case,
      production: production,
      scope: scope
    } do
      body = json_response(api_post(raw, @path <> "/rollback", %{revision: 1}), 200)

      assert body["revision"] == 3
      assert body["model_id"] == model.id
      assert body["model"] == "anthropic/claude-sonnet-4"
      assert body["id"] != second.id

      assert {:ok, live} = Deployments.current_deployment(use_case.id, production.id, scope)
      assert live.revision == 3
      assert live.model_id == model.id
    end

    test "404 for a revision that does not exist, listing the ones that do", %{raw: raw} do
      conn = api_post(raw, @path <> "/rollback", %{revision: 9})

      assert %{"error" => %{"code" => "not_found", "details" => details}} =
               json_response(conn, 404)

      assert details["revision"] == 9
      assert details["available_revisions"] == [2, 1]
    end

    test "400 without a positive integer revision", %{raw: raw} do
      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(api_post(raw, @path <> "/rollback", %{}), 400)

      assert message =~ "revision"

      assert %{"error" => %{"code" => "invalid_request"}} =
               json_response(api_post(raw, @path <> "/rollback", %{revision: "1"}), 400)
    end
  end

  test "another organization's key cannot commit a pin here", %{model: model} do
    other_raw = cli_token_fixture(user_fixture())

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(api_post(other_raw, @path, %{model_id: model.id}), 404)
  end
end
