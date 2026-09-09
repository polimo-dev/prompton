defmodule PromptOnWeb.ProviderCatalogReuseTest do
  use PromptOnWeb.ConnCase, async: false

  alias PromptOn.Catalog.ProviderCatalog
  alias PromptOn.Fixtures
  alias PromptOnWeb.API.V1.Management.ModelSetup

  test "organization settings, Arena and management registration share one catalog fetch", %{
    conn: conn
  } do
    previous_options = Application.get_env(:prompton, :provider_catalog_req_options)
    test_pid = self()
    ProviderCatalog.reset_cache()

    Application.put_env(:prompton, :provider_catalog_req_options,
      plug: fn conn ->
        send(test_pid, :catalog_fetched)

        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "openai/shared-model",
              "name" => "OpenAI: Shared model",
              "context_length" => 128_000,
              "pricing" => %{"prompt" => "0.000001", "completion" => "0.000003"}
            }
          ]
        })
      end
    )

    on_exit(fn ->
      Application.put_env(:prompton, :provider_catalog_req_options, previous_options)
      ProviderCatalog.reset_cache()
    end)

    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "catalog-reuse"})
    use_case = Fixtures.use_case_fixture(project, %{key: "chat"})
    Fixtures.prompt_version_fixture(use_case)
    conn = log_in_user(conn, user)

    {:ok, settings, _html} =
      live(conn, ~p"/personal/settings?tab=general&model-picker=evaluation")

    render_async(settings)
    assert has_element?(settings, "#org-model-row-openai-shared-model")
    assert_received :catalog_fetched

    {:ok, arena, _html} =
      live(
        conn,
        ~p"/personal/#{project.slug}/use-cases/#{use_case.key}/prompt?tab=arena&models=1"
      )

    render_async(arena)
    assert has_element?(arena, "#pick-row-openai-shared-model")
    refute_received :catalog_fetched

    assert {:ok, model} = ModelSetup.register(Fixtures.scope(project), "openai/shared-model", %{})
    assert model.display_name == "OpenAI: Shared model"
    assert model.context_length == 128_000
    assert model.pricing["input_per_m"] == 1.0
    refute_received :catalog_fetched

    settings |> element("#select-org-model-openai-shared-model") |> render_click()
    settings |> element("#open-draft-model-picker") |> render_click()
    render_async(settings)
    assert has_element?(settings, "#org-model-row-openai-shared-model")
    refute_received :catalog_fetched
  end
end
