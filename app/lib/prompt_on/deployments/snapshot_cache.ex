defmodule PromptOn.Deployments.SnapshotCache do
  @moduledoc """
  In-memory cache (ETS) holding the **use-cases schema v4 body + decoded result** of one environment.

  Its reason to exist is the **polling path of config-fetch serving** (`GET /api/v1/use-cases`,
  docs/api.md): PromptOn does not sit in the app's request path; instead, apps **poll** this
  endpoint. `Snapshot.build/2` is five round trips plus canonical JSON encoding, and
  `PromptOnSDK.UseCaseDocument.decode/1` is CPU work that unpacks that map into structs. Doing both for
  every poll (including requests that end in 304 because nothing changed) makes the serving cost
  proportional to the polling interval.

  **`POST /use-cases/:key/prompt` deliberately bypasses this cache.** It is the smoke test a person runs right
  after deploying and a debugging entry point, so "the use case just created, the revision just
  committed" must show up immediately, and it is not the side that carries polling cost.

  (Before the proxy mode was removed on 2026-09-01, the proxy's hot path was this cache's reason to
  exist. The cache stayed and **its consumer moved to the snapshot controller**.)

  ## Contract

  - The key is the **environment id**. The value is
    `%{data: %PromptOnSDK.UseCaseDocument{}, etag: String.t(), body: binary(), last_modified: DateTime.t(), warnings: [term()]}`
    where `body` is the exact canonical bytes that were hashed (`GET /use-cases` sends it as is).
  - Within the TTL a fetch is one ETS read (zero DB reads). Default 5 seconds; change it with
    `config :prompton, :snapshot_cache_ttl_ms`.
  - After the TTL it **revalidates**: the snapshot is assembled again (the only DB access), and if
    the ETag is unchanged the already-decoded value is reused as is and only the expiry is pushed
    back (zero decoding cost). If it differs, the entry is decoded anew and swapped in. When the
    ETag is unchanged, `last_modified` **keeps its previous value** too: the ETag is a hash of the
    body, so the body is identical, and `Last-Modified` is an informational header that is not used
    for cache validation.
  - When revalidation fails (`{:error, _}`) **the stale value is not served**: an archived
    environment/project makes `Snapshot.build/2` return `{:error, :not_found}`, and papering over
    that with a stale entry would mean archiving never takes effect.
  - On a cache hit the archive check of `Snapshot.build/2` is skipped as well. This is safe because
    `PromptOnWeb.Plugs.ApiKeyAuth` reads the key's project and environment **on every request** and
    cuts off with 401 when archived; this cache does not stand in for that check.
  - Right after a deployment, an old revision may be served for at most the TTL (5 seconds). That
    is the same property as `GET /use-cases` polling (the SDK path); call `invalidate/1` when
    immediate effect is needed.
  - Cache stampedes are not prevented: at the moment the TTL expires, N concurrent requests may
    each reassemble. That is N times per 5 seconds per environment with identical results (last
    write wins), so there is no lock.

  The table is `:public` because the request process that revalidated must write directly (sending
  through the GenServer would copy the large entry into the mailbox once more). The GenServer is
  only the table owner.

  ## Telemetry (doubles as the test seam)

  `[:prompton, :snapshot_cache, :hit | :miss | :revalidate]`, measurement `%{count: 1}`,
  metadata `%{environment_id: id}` (+ `changed?` for `:revalidate`).
  "The second call does not touch the DB" is verified through these events.
  """

  use GenServer

  alias PromptOn.Deployments.Snapshot
  alias PromptOn.Projects.Environment
  alias PromptOnSDK.UseCaseDocument

  @table :prompton_snapshot_cache
  @default_ttl_ms 5_000

  @type entry :: %{
          data: UseCaseDocument.t(),
          etag: String.t(),
          body: binary(),
          last_modified: DateTime.t(),
          warnings: [term()]
        }

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "TTL (ms). `config :prompton, :snapshot_cache_ttl_ms` (default 5,000)."
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms do
    case Application.get_env(:prompton, :snapshot_cache_ttl_ms, @default_ttl_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @default_ttl_ms
    end
  end

  @doc """
  Returns the snapshot entry of an environment. `opts` is passed straight to `Snapshot.build/2`
  (`:actor` required, `:tenant`). When the cache is fresh `opts` is unused; it is needed only to
  assemble.
  """
  @spec fetch(Environment.t() | Ash.UUID.t(), keyword()) :: {:ok, entry()} | {:error, term()}
  def fetch(env_or_id, opts) do
    id = environment_id(env_or_id)

    case lookup(id) do
      {:fresh, entry} ->
        emit(:hit, id)
        {:ok, entry}

      {:stale, entry} ->
        revalidate(env_or_id, id, entry, opts)

      :miss ->
        emit(:miss, id)
        build_and_put(env_or_id, id, opts)
    end
  end

  @doc """
  Drops the entry of that environment (the next fetch assembles from scratch). For when a
  deployment commit must take effect immediately.
  """
  @spec invalidate(Environment.t() | Ash.UUID.t()) :: :ok
  def invalidate(env_or_id) do
    with table when table != :undefined <- :ets.whereis(@table) do
      :ets.delete(table, environment_id(env_or_id))
    end

    :ok
  end

  @doc """
  **Expires** the entry while keeping it (the next fetch revalidates by ETag). For testing the TTL
  expiry path.

  The expiry value is "1ms in the past", not `0`: `System.monotonic_time/1` may start negative, so
  `0` could lie in the future.
  """
  @spec expire(Environment.t() | Ash.UUID.t()) :: :ok
  def expire(env_or_id) do
    with table when table != :undefined <- :ets.whereis(@table) do
      :ets.update_element(table, environment_id(env_or_id), {3, now_ms() - 1})
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

  defp revalidate(env_or_id, id, entry, opts) do
    case Snapshot.build(env_or_id, opts) do
      {:ok, %{etag: etag} = snapshot} ->
        if etag == entry.etag do
          emit(:revalidate, id, %{changed?: false})
          put(id, entry)
          {:ok, entry}
        else
          emit(:revalidate, id, %{changed?: true})
          decode_and_put(id, snapshot)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_and_put(env_or_id, id, opts) do
    with {:ok, snapshot} <- Snapshot.build(env_or_id, opts), do: decode_and_put(id, snapshot)
  end

  defp decode_and_put(id, snapshot) do
    case UseCaseDocument.decode(snapshot.map) do
      {:ok, data, warnings} ->
        entry = %{
          data: data,
          etag: snapshot.etag,
          body: snapshot.body,
          last_modified: snapshot.last_modified,
          warnings: warnings
        }

        put(id, entry)
        {:ok, entry}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup(id) do
    case table_lookup(id) do
      [{^id, entry, deadline}] ->
        if deadline > now_ms(), do: {:fresh, entry}, else: {:stale, entry}

      _ ->
        :miss
    end
  end

  # Without the table (unit tests running outside the supervision tree) it works without caching.
  defp table_lookup(id) do
    case :ets.whereis(@table) do
      :undefined -> []
      table -> :ets.lookup(table, id)
    end
  end

  defp put(id, entry) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.insert(table, {id, entry, now_ms() + ttl_ms()})
    end

    :ok
  end

  defp environment_id(%Environment{id: id}), do: id
  defp environment_id(id) when is_binary(id), do: id

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp emit(event, environment_id, metadata \\ %{}) do
    :telemetry.execute(
      [:prompton, :snapshot_cache, event],
      %{count: 1},
      Map.put(metadata, :environment_id, environment_id)
    )
  end
end
