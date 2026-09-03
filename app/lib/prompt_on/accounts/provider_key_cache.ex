defmodule PromptOn.Accounts.ProviderKeyCache do
  @moduledoc """
  A short-lived cache (ETS) of the **decrypted** BYOK key per organization × provider.

  The paths where the server calls an LLM directly (arena, AI drafts, and P1's experiments,
  judges, and always-on auto-grading) need a provider key on every call, but `ProviderKey.secret`
  is `decrypt_by_default []`, so each read carries a **DB query + AES-GCM decryption**. To get rid
  of that, it is cached for 1 minute (default) under `{organization_id, provider}`.

  > As of the proxy-mode removal on 2026-09-01 there are no production callers:
  > `PromptOn.LLM.OpenRouter` still reads `ProviderKey` directly and updates `last_used_at`. The
  > hook becomes necessary the moment bulk grading (§5 Evals) lands, so it is kept (product
  > decision, agent-first-spec §2).

  Since key ownership moved from the project to the **organization** (2026-09-01), the cache key
  is the organization id too: projects in the same organization share one entry.

  - The absence of a value (negative cache) is held for the same TTL, so an organization without
    a key does not hit the DB on every call.
  - `:register` / `:rotate` / `:revoke` clear the matching entry via
    `PromptOn.Accounts.ProviderKey.Changes.BustCache`. So **changing a key in the UI takes effect
    immediately.** The TTL is the safety net for changes that do not go through that hook (direct
    SQL, another node); in those cases the staleness window is at most `ttl_ms/0` (default 60
    seconds), and with multiple nodes the hook clears **only its own node's ETS**, so other nodes
    use the old key for that window.
  - If the organization has no key and the provider is `:openrouter`, it falls back to the app
    setting `:openrouter_api_key` (`PTN_OPENROUTER_API_KEY`) (plan.md §5.4; the same key
    resolution order as `PromptOn.LLM.OpenRouter`). This value is not cached (an Application env
    lookup is already an ETS read).

  The plaintext key stays in ETS for at most a TTL; within one node that is the same trust
  boundary as the process heap and the `Application` env (it ends up in dumps and core files
  anyway). The table is `:public`, but this module is the only one that uses it.

  Telemetry: `[:prompton, :provider_key_cache, :hit | :miss]`, measurements `%{count: 1}`,
  metadata `%{organization_id:, provider:}`.
  """

  use GenServer

  alias PromptOn.Accounts
  alias PromptOn.Accounts.ProviderKey

  @table :prompton_provider_key_cache
  @default_ttl_ms 60_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "TTL in ms. `config :prompton, :provider_key_cache_ttl_ms` (default 60,000)."
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms do
    case Application.get_env(:prompton, :provider_key_cache_ttl_ms, @default_ttl_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @default_ttl_ms
    end
  end

  @doc """
  The raw provider key. Order: cache → the organization's `ProviderKey` → (openrouter only) the
  app setting. `{:error, :no_provider_key}` if none.
  """
  @spec fetch(Ash.UUID.t(), atom()) :: {:ok, String.t()} | {:error, :no_provider_key}
  def fetch(organization_id, provider) when is_binary(organization_id) and is_atom(provider) do
    cached =
      case lookup(organization_id, provider) do
        {:ok, value} ->
          emit(:hit, organization_id, provider)
          value

        :miss ->
          emit(:miss, organization_id, provider)
          value = read(organization_id, provider)
          put(organization_id, provider, value)
          value
      end

    case cached do
      {:ok, secret} -> {:ok, secret}
      :none -> app_env_fallback(provider)
    end
  end

  @doc "Drops that organization × provider entry (the register/rotate/revoke hook)."
  @spec invalidate(Ash.UUID.t(), atom()) :: :ok
  def invalidate(organization_id, provider) do
    with table when table != :undefined <- :ets.whereis(@table) do
      :ets.delete(table, {organization_id, provider})
    end

    :ok
  end

  @doc "Empties the whole cache."
  @spec flush() :: :ok
  def flush do
    with table when table != :undefined <- :ets.whereis(@table) do
      :ets.delete_all_objects(table)
    end

    :ok
  end

  # ---------------------------------------------------------------------------

  # `{:ok, secret}` | `:none`; negative results are cached too.
  defp read(organization_id, provider) do
    if provider in ProviderKey.providers() do
      Accounts.active_provider_key(organization_id, provider,
        actor: PromptOn.SystemActor.new(),
        load: [:secret]
      )
      |> case do
        {:ok, %ProviderKey{secret: secret}} when is_binary(secret) and secret != "" ->
          {:ok, secret}

        _ ->
          :none
      end
    else
      :none
    end
  rescue
    # A failed key lookup (DB outage etc.) is not cemented as a negative cache entry; the next
    # call retries.
    _ -> :none
  end

  defp app_env_fallback(:openrouter) do
    case Application.get_env(:prompton, :openrouter_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_provider_key}
    end
  end

  defp app_env_fallback(_provider), do: {:error, :no_provider_key}

  defp lookup(organization_id, provider) do
    key = {organization_id, provider}

    case table_lookup(key) do
      [{^key, value, deadline}] -> if deadline > now_ms(), do: {:ok, value}, else: :miss
      _ -> :miss
    end
  end

  defp table_lookup(key) do
    case :ets.whereis(@table) do
      :undefined -> []
      table -> :ets.lookup(table, key)
    end
  end

  defp put(organization_id, provider, value) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.insert(table, {{organization_id, provider}, value, now_ms() + ttl_ms()})
    end

    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp emit(event, organization_id, provider) do
    :telemetry.execute([:prompton, :provider_key_cache, event], %{count: 1}, %{
      organization_id: organization_id,
      provider: provider
    })
  end
end
