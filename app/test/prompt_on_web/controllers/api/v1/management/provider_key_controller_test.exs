defmodule PromptOnWeb.API.V1.Management.ProviderKeyControllerTest do
  @moduledoc """
  Organization BYOK key (§3.7, what turns on the arena and evaluation). **The raw secret never
  leaves in any response.**
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  alias PromptOn.Accounts

  @secret "sk-or-v1-0123456789abcdef0123456789abcdef4Xa2"

  setup do
    user = user_fixture()
    org = organization_for(user)
    raw = cli_token_fixture(user)

    %{user: user, org: org, raw: raw}
  end

  test "reports no key before one is registered", %{raw: raw} do
    assert json_response(api_get(raw, ~p"/api/v1/orgs/personal/provider-key"), 200) == %{
             "connected" => false,
             "provider" => "openrouter"
           }
  end

  test "registers a key and reports only the masked hint", %{raw: raw, org: org} do
    body =
      json_response(
        api_post(raw, ~p"/api/v1/orgs/personal/provider-key", %{secret: @secret}),
        201
      )

    assert body["connected"] == true
    assert body["provider"] == "openrouter"
    assert body["label"] == "default"
    assert body["hint"] == "sk-or-v1-••••4Xa2"
    refute body["hint"] =~ "0123456789"

    status = json_response(api_get(raw, ~p"/api/v1/orgs/personal/provider-key"), 200)
    assert status["hint"] == "sk-or-v1-••••4Xa2"
    refute Map.has_key?(status, "secret")

    assert {:ok, [stored]} = Accounts.list_provider_keys(org.id, actor: system_actor())
    assert stored.organization_id == org.id
    assert stored.id == body["id"]
  end

  test "409 with the existing key when the label is taken", %{raw: raw, org: org} do
    existing = provider_key_fixture(org, secret: @secret)

    conn =
      api_post(raw, ~p"/api/v1/orgs/personal/provider-key", %{
        secret: "sk-or-v1-anotheronegoeshere9999"
      })

    assert %{"error" => %{"code" => "conflict", "details" => details}} = json_response(conn, 409)
    assert details["provider_key"]["id"] == existing.id
    assert details["provider_key"]["hint"]
    refute details["provider_key"]["hint"] =~ "0123456789"
  end

  test "a second label is allowed", %{raw: raw} do
    assert json_response(
             api_post(raw, ~p"/api/v1/orgs/personal/provider-key", %{secret: @secret}),
             201
           )

    body =
      json_response(
        api_post(raw, ~p"/api/v1/orgs/personal/provider-key", %{
          secret: "sk-or-v1-secondkeygoeshere777788",
          label: "arena"
        }),
        201
      )

    assert body["label"] == "arena"
  end

  test "400 without a secret", %{raw: raw} do
    assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
             json_response(api_post(raw, ~p"/api/v1/orgs/personal/provider-key", %{}), 400)

    assert message =~ "secret is required"
  end

  test "the key belongs to the organization, not to other organizations", %{raw: raw, org: org} do
    _mine = provider_key_fixture(org, secret: @secret)

    other_raw = cli_token_fixture(user_fixture())

    assert json_response(api_get(other_raw, ~p"/api/v1/orgs/personal/provider-key"), 200) == %{
             "connected" => false,
             "provider" => "openrouter"
           }

    assert json_response(api_get(raw, ~p"/api/v1/orgs/personal/provider-key"), 200)["connected"] ==
             true
  end
end
