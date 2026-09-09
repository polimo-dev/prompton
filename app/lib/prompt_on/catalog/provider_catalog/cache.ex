defmodule PromptOn.Catalog.ProviderCatalog.Cache do
  @moduledoc """
  Node-local cache for OpenRouter's public model list.

  The catalog is public provider metadata, so it is cached once per node without tenant IDs,
  provider keys, or organization selections. A missing cache process is treated as library mode by
  `PromptOn.Catalog.ProviderCatalog`, which falls back to a direct fetch.
  """

  use GenServer

  alias PromptOn.Catalog.ProviderCatalog

  @ttl_ms :timer.minutes(15)
  @failure_backoff_ms :timer.seconds(30)
  @max_reason_bytes 240

  @type reason :: String.t()
  @type catalog :: [ProviderCatalog.provider_model()]

  defstruct data: nil,
            fetched_at: nil,
            loading: nil,
            last_error: nil,
            failed_at: nil,
            ttl_ms: @ttl_ms,
            failure_backoff_ms: @failure_backoff_ms,
            fetch: nil,
            clock: nil

  @doc false
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Read the catalog through a cache process, falling back to direct fetch if it is absent."
  @spec list_openrouter_models(keyword()) :: {:ok, catalog()} | {:error, reason()}
  def list_openrouter_models(opts \\ []) do
    server = Keyword.get(opts, :cache_server, __MODULE__)

    if alive?(server) do
      GenServer.call(server, {:list, Keyword.take(opts, [:refresh])}, :infinity)
    else
      ProviderCatalog.fetch_openrouter_models(opts)
    end
  end

  @doc "Drop cached catalog data and failures."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    if alive?(server), do: GenServer.call(server, :reset), else: :ok
  end

  @doc "Mark the cached catalog stale while preserving the last successful response."
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    if alive?(server), do: GenServer.call(server, :invalidate), else: :ok
  end

  @doc "Return the last bounded refresh failure reason, when a cache process is running."
  @spec last_error(GenServer.server()) :: reason() | nil
  def last_error(server \\ __MODULE__) do
    if alive?(server), do: GenServer.call(server, :last_error), else: nil
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
      failure_backoff_ms: Keyword.get(opts, :failure_backoff_ms, @failure_backoff_ms),
      fetch: Keyword.get(opts, :fetch, &ProviderCatalog.fetch_openrouter_models/1),
      clock: Keyword.get(opts, :clock, &System.monotonic_time/1)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:list, opts}, from, state) do
    now = now(state)
    refresh? = Keyword.get(opts, :refresh, false)

    cond do
      fresh?(state, now) and not refresh? ->
        {:reply, {:ok, state.data}, state}

      cooling_down?(state, now) and not refresh? ->
        {:reply, cached_or_error(state), state}

      state.loading ->
        {:noreply, add_waiter(state, from)}

      true ->
        {:noreply, state |> add_waiter(from) |> start_load()}
    end
  end

  def handle_call(:reset, _from, state) do
    state = stop_loading(state, {:error, "provider catalog cache reset"})
    state = %{state | data: nil, fetched_at: nil, loading: nil, last_error: nil, failed_at: nil}
    {:reply, :ok, state}
  end

  def handle_call(:invalidate, _from, state) do
    {:reply, :ok, %{state | fetched_at: nil}}
  end

  def handle_call(:last_error, _from, state) do
    {:reply, state.last_error, state}
  end

  @impl true
  def handle_info({:catalog_loaded, pid, result}, %{loading: %{pid: pid, froms: froms}} = state) do
    Process.demonitor(state.loading.ref, [:flush])
    now = now(state)

    {reply, state} =
      case result do
        {:ok, data} ->
          {{:ok, data},
           %{state | data: data, fetched_at: now, loading: nil, last_error: nil, failed_at: nil}}

        {:error, reason} ->
          reason = bounded_reason(reason)
          state = %{state | loading: nil, last_error: reason, failed_at: now}
          {cached_or_error(state), state}
      end

    Enum.each(froms, &GenServer.reply(&1, reply))
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{loading: %{ref: ref, froms: froms}} = state
      ) do
    now = now(state)
    reason = bounded_reason("openrouter request failed (#{inspect(reason)})")
    state = %{state | loading: nil, last_error: reason, failed_at: now}
    reply = cached_or_error(state)

    Enum.each(froms, &GenServer.reply(&1, reply))
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_loading(state, nil)
    :ok
  end

  defp alive?(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(_server), do: false

  defp start_load(state) do
    parent = self()
    fetch = state.fetch

    {pid, ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {:catalog_loaded, self(), safe_fetch(fetch)}) end,
        [:link, :monitor]
      )

    %{state | loading: %{pid: pid, ref: ref, froms: state.loading.froms}}
  end

  defp safe_fetch(fetch) do
    case fetch.([]) do
      {:ok, data} when is_list(data) -> {:ok, data}
      {:error, reason} -> {:error, reason}
      other -> {:error, "unexpected provider catalog result #{inspect(other)}"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp add_waiter(%{loading: nil} = state, from), do: %{state | loading: %{froms: [from]}}

  defp add_waiter(%{loading: loading} = state, from),
    do: %{state | loading: %{loading | froms: [from | loading.froms]}}

  defp stop_loading(%{loading: nil} = state, _reply), do: state

  defp stop_loading(%{loading: %{pid: pid, ref: ref, froms: froms}} = state, reply) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])

    if reply do
      Enum.each(froms, &GenServer.reply(&1, reply))
    end

    %{state | loading: nil}
  end

  defp cached_or_error(%{data: nil, last_error: reason}), do: {:error, reason}
  defp cached_or_error(%{data: data}), do: {:ok, data}

  defp fresh?(%{data: nil}, _now), do: false
  defp fresh?(%{fetched_at: nil}, _now), do: false
  defp fresh?(state, now), do: now - state.fetched_at < state.ttl_ms

  defp cooling_down?(%{failed_at: nil}, _now), do: false
  defp cooling_down?(state, now), do: now - state.failed_at < state.failure_backoff_ms

  defp now(%{clock: clock}), do: clock.(:millisecond)

  defp bounded_reason(reason) do
    reason
    |> to_string()
    |> String.slice(0, @max_reason_bytes)
  end
end
