defmodule PromptOn.Accounts.ProviderKeyCacheTest do
  # Runs synchronously: it touches the global ETS table plus the `:openrouter_api_key` /
  # `:provider_key_cache_ttl_ms` Application env.
  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures

  alias PromptOn.Accounts
  alias PromptOn.Accounts.ProviderKeyCache

  @events [
    [:prompton, :provider_key_cache, :hit],
    [:prompton, :provider_key_cache, :miss]
  ]

  setup do
    ProviderKeyCache.flush()

    previous = Application.get_env(:prompton, :openrouter_api_key)
    Application.delete_env(:prompton, :openrouter_api_key)

    handler = "provider-key-cache-#{System.unique_integer([:positive])}"
    :telemetry.attach_many(handler, @events, &__MODULE__.forward_event/4, self())

    on_exit(fn ->
      :telemetry.detach(handler)
      ProviderKeyCache.flush()

      if is_nil(previous),
        do: Application.delete_env(:prompton, :openrouter_api_key),
        else: Application.put_env(:prompton, :openrouter_api_key, previous)
    end)

    user = user_fixture()
    %{user: user, org: organization_for(user)}
  end

  @doc false
  def forward_event(event, _measurements, metadata, pid), do: send(pid, {:cache, event, metadata})

  test "decrypts once and serves the cached secret afterwards", %{org: org} do
    key = provider_key_fixture(org, secret: "sk-or-v1-cached-secret-0001")

    assert {:ok, "sk-or-v1-cached-secret-0001"} = ProviderKeyCache.fetch(org.id, :openrouter)

    assert_receive {:cache, [:prompton, :provider_key_cache, :miss], %{organization_id: _}}

    # Even with the record deleted, the cached value comes back within the TTL = the second call
    # did not hit the DB / decryption. (`:destroy` is the only write without a cache-bust hook,
    # which is why it can be used to prove caching.)
    :ok = Ash.destroy!(key, actor: system_actor())

    assert {:ok, "sk-or-v1-cached-secret-0001"} = ProviderKeyCache.fetch(org.id, :openrouter)

    assert_receive {:cache, [:prompton, :provider_key_cache, :hit], _}
    refute_receive {:cache, [:prompton, :provider_key_cache, :miss], _}, 20

    ProviderKeyCache.invalidate(org.id, :openrouter)
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :openrouter)
  end

  test "an organization without a key is a cached negative, and registering busts it", %{org: org} do
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :openrouter)
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :openrouter)
    assert_receive {:cache, [:prompton, :provider_key_cache, :hit], _}

    _key = provider_key_fixture(org, secret: "sk-or-v1-fresh-000000000001")

    assert {:ok, "sk-or-v1-fresh-000000000001"} = ProviderKeyCache.fetch(org.id, :openrouter)
  end

  test "rotate and revoke bust the cache", %{org: org} do
    key = provider_key_fixture(org, secret: "sk-or-v1-first-000000000001")
    assert {:ok, "sk-or-v1-first-000000000001"} = ProviderKeyCache.fetch(org.id, :openrouter)

    {:ok, rotated} =
      Accounts.rotate_provider_key(key, %{secret: "sk-or-v1-second-00000000001"},
        actor: system_actor()
      )

    assert {:ok, "sk-or-v1-second-00000000001"} = ProviderKeyCache.fetch(org.id, :openrouter)

    {:ok, _revoked} = Accounts.revoke_provider_key(rotated, %{}, actor: system_actor())

    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :openrouter)
  end

  test "keys are scoped per (organization, provider)", %{org: org} do
    other = organization_for(user_fixture())
    _openrouter = provider_key_fixture(org, secret: "sk-or-v1-mine-0000000000001")

    assert {:ok, "sk-or-v1-mine-0000000000001"} = ProviderKeyCache.fetch(org.id, :openrouter)
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(other.id, :openrouter)

    # BYOK is OpenRouter only (2026-09-01): other providers cannot be registered, so the cache does
    # not hit the DB for them either.
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :groq)
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :anthropic)
  end

  test "every project of the organization shares one cache entry", %{user: user, org: org} do
    _key = provider_key_fixture(org, secret: "sk-or-v1-shared-00000000001")
    one = project_fixture(%{user: user, organization: org})
    two = project_fixture(%{user: user, organization: org})

    assert {:ok, "sk-or-v1-shared-00000000001"} =
             ProviderKeyCache.fetch(one.organization_id, :openrouter)

    assert_receive {:cache, [:prompton, :provider_key_cache, :miss], _}

    assert {:ok, "sk-or-v1-shared-00000000001"} =
             ProviderKeyCache.fetch(two.organization_id, :openrouter)

    assert_receive {:cache, [:prompton, :provider_key_cache, :hit], _}
    refute_receive {:cache, [:prompton, :provider_key_cache, :miss], _}, 20
  end

  test "providers outside the BYOK list never reach the database", %{org: org} do
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :not_a_provider)
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :google)
  end

  test "the application env is an openrouter-only fallback and is not cached", %{org: org} do
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :groq)

    Application.put_env(:prompton, :openrouter_api_key, "env-key")

    assert {:ok, "env-key"} = ProviderKeyCache.fetch(org.id, :openrouter)
    # groq has no fallback
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :groq)

    # The fallback is not baked into the cache: removing the config makes it vanish at once (the
    # negative cache entry stays).
    Application.delete_env(:prompton, :openrouter_api_key)
    assert {:error, :no_provider_key} = ProviderKeyCache.fetch(org.id, :openrouter)

    # The organization key always beats the app config.
    Application.put_env(:prompton, :openrouter_api_key, "env-key")
    _key = provider_key_fixture(org, secret: "sk-or-v1-org-00000000000001")
    assert {:ok, "sk-or-v1-org-00000000000001"} = ProviderKeyCache.fetch(org.id, :openrouter)
  end
end
