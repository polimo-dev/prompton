defmodule PromptOnWeb.API.V1.Management.ModelControllerTest do
  @moduledoc """
  `/api/v1/projects/:project/models`: the catalog entries a deployment pin points at.
  Checks that a bare `model_id` is enough to register one, and that pricing is filled in from the
  public OpenRouter listing (the test configuration keeps
  `config :prompton, :provider_catalog_req_options` off real HTTP).
  """
  # `async: false`: the pricing enrichment test swaps out `:provider_catalog_req_options`, which is
  # global configuration.
  use PromptOnWeb.ConnCase, async: false

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  alias PromptOn.Catalog

  setup do
    user = user_fixture()
    org = organization_for(user)
    project = project_fixture(%{user: user, organization: org, slug: "heydiary"})
    raw = cli_token_fixture(user)

    %{project: project, raw: raw, scope: scope(project)}
  end

  describe "POST /models" do
    test "registers with model_id alone, defaulting the provider and the display name", %{
      raw: raw,
      scope: scope
    } do
      conn =
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models", %{
          model_id: "anthropic/claude-sonnet-4"
        })

      body = json_response(conn, 201)

      assert body["provider"] == "openrouter"
      assert body["model_id"] == "anthropic/claude-sonnet-4"
      assert body["display_name"] == "anthropic/claude-sonnet-4"
      assert body["status"] == "active"

      assert {:ok, model} =
               Catalog.get_model_by_provider_model(
                 :openrouter,
                 "anthropic/claude-sonnet-4",
                 scope
               )

      assert model.id == body["id"]
    end

    test "takes the caller's own metadata, pricing and capabilities", %{raw: raw} do
      conn =
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models", %{
          model_id: "openai/gpt-5-mini",
          display_name: "GPT-5 mini",
          metadata: %{"description_key" => "chat_model.gpt5_mini"},
          provider_options: %{"only" => ["OpenAI"]},
          pricing: %{
            "input_per_m" => 0.25,
            "output_per_m" => 2.0,
            "currency" => "USD",
            "unit" => "token"
          },
          context_length: 400_000,
          capabilities: ["tools", "streaming"]
        })

      body = json_response(conn, 201)

      assert body["display_name"] == "GPT-5 mini"
      assert body["metadata"] == %{"description_key" => "chat_model.gpt5_mini"}
      assert body["provider_options"] == %{"only" => ["OpenAI"]}
      assert body["pricing"]["input_per_m"] == 0.25
      assert body["context_length"] == 400_000
      assert Enum.sort(body["capabilities"]) == ["streaming", "tools"]
    end

    test "fills pricing and context length from the OpenRouter catalog", %{raw: raw} do
      catalog = %{
        "data" => [
          %{
            "id" => "anthropic/claude-sonnet-4",
            "name" => "Anthropic: Claude Sonnet 4",
            "context_length" => 200_000,
            "pricing" => %{"prompt" => "0.000003", "completion" => "0.000015"}
          }
        ]
      }

      Application.put_env(:prompton, :provider_catalog_req_options,
        plug: fn conn -> Req.Test.json(conn, catalog) end
      )

      on_exit(fn ->
        Application.put_env(:prompton, :provider_catalog_req_options,
          plug: fn conn -> Req.Test.json(conn, %{"data" => []}) end
        )
      end)

      conn =
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models", %{
          model_id: "anthropic/claude-sonnet-4"
        })

      body = json_response(conn, 201)

      assert body["display_name"] == "Anthropic: Claude Sonnet 4"
      assert body["context_length"] == 200_000

      assert body["pricing"] == %{
               "input_per_m" => 3.0,
               "output_per_m" => 15.0,
               "currency" => "USD",
               "unit" => "token"
             }
    end

    test "409 with the existing model", %{raw: raw, project: project} do
      existing = model_fixture(project, %{model_id: "already/there"})

      conn =
        api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models", %{
          model_id: "already/there"
        })

      assert %{"error" => %{"code" => "conflict", "details" => details}} =
               json_response(conn, 409)

      assert details["model"]["id"] == existing.id
    end

    test "400 without a model_id and on bad pricing", %{raw: raw} do
      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(
                 api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models", %{}),
                 400
               )

      assert message =~ "model_id is required"

      assert %{"error" => %{"code" => "invalid_request"}} =
               json_response(
                 api_post(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models", %{
                   model_id: "bad/pricing",
                   pricing: %{"input_per_m" => -1}
                 }),
                 400
               )
    end
  end

  describe "GET /models" do
    test "lists this project's catalog, archived entries excluded", %{
      raw: raw,
      project: project,
      scope: scope
    } do
      _keep = model_fixture(project, %{model_id: "a/keep"})
      gone = model_fixture(project, %{model_id: "z/gone"})
      {:ok, _archived} = Catalog.archive_model(gone, scope)

      body = json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models"), 200)

      assert Enum.map(body["models"], & &1["model_id"]) == ["a/keep"]
    end

    test "another project's catalog is invisible", %{raw: raw} do
      other_project = project_fixture(%{slug: "elsewhere"})
      _model = model_fixture(other_project, %{model_id: "secret/model"})

      body = json_response(api_get(raw, ~p"/api/v1/orgs/personal/projects/heydiary/models"), 200)
      assert body["models"] == []
    end
  end
end
