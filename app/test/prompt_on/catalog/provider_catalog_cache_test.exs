defmodule PromptOn.Catalog.ProviderCatalogCacheTest do
  use ExUnit.Case, async: true

  alias PromptOn.Catalog.ProviderCatalog
  alias PromptOn.Catalog.ProviderCatalog.Cache

  test "missing cache process falls back to an uncached fetch" do
    parent = self()

    {:ok, models} =
      Cache.list_openrouter_models(
        cache_server: :missing_provider_catalog_cache,
        req_options: [
          plug: fn conn ->
            send(parent, :fetched)
            Req.Test.json(conn, %{"data" => [%{"id" => "library/model"}]})
          end
        ]
      )

    assert [%{model_id: "library/model"}] = models
    assert_received :fetched
  end

  test "concurrent cold calls share one provider request" do
    parent = self()
    agent = start_agent(0)
    {:ok, cache} = start_cache(fetch: blocking_fetch(parent, agent, [model("shared/model")]))

    tasks =
      for _ <- 1..5 do
        Task.async(fn -> ProviderCatalog.list_openrouter_models(cache_server: cache) end)
      end

    assert_receive {:fetch_started, fetch_pid}
    refute_receive {:fetch_started, _pid}, 50

    send(fetch_pid, :release_fetch)

    assert Enum.map(tasks, &Task.await(&1)) == List.duplicate({:ok, [model("shared/model")]}, 5)
    assert Agent.get(agent, & &1) == 1
  end

  test "concurrent explicit refreshes join one in-flight request" do
    parent = self()
    agent = start_agent(0)
    {:ok, cache} = start_cache(fetch: blocking_fetch(parent, agent, [model("shared/model")]))

    requests = for _ <- 1..5, do: :gen_server.send_request(cache, {:list, [refresh: true]})
    assert_receive {:fetch_started, fetch_pid}
    assert length(:sys.get_state(cache).loading.froms) == 5
    send(fetch_pid, :release_fetch)

    for request <- requests do
      assert :gen_server.receive_response(request, 1_000) ==
               {:reply, {:ok, [model("shared/model")]}}
    end

    assert Agent.get(agent, & &1) == 1
  end

  test "reset replies to waiters and stops an in-flight fetch" do
    parent = self()
    agent = start_agent(0)
    {:ok, cache} = start_cache(fetch: blocking_fetch(parent, agent, [model("reset/model")]))

    task = Task.async(fn -> ProviderCatalog.list_openrouter_models(cache_server: cache) end)

    assert_receive {:fetch_started, fetch_pid}
    monitor_ref = Process.monitor(fetch_pid)

    assert :ok = ProviderCatalog.reset_cache(cache)
    assert {:error, "provider catalog cache reset"} = Task.await(task)
    assert_receive {:DOWN, ^monitor_ref, :process, ^fetch_pid, :killed}
  end

  test "fresh calls use cache until ttl expires, and refresh bypasses ttl" do
    {clock, clock_agent} = start_clock(0)
    agent = start_agent(0)
    {:ok, cache} = start_cache(fetch: counted_fetch(agent), clock: clock, ttl_ms: 100)

    assert {:ok, [model: 1]} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    assert {:ok, [model: 1]} = ProviderCatalog.list_openrouter_models(cache_server: cache)

    advance(clock_agent, 99)
    assert {:ok, [model: 1]} = ProviderCatalog.list_openrouter_models(cache_server: cache)

    advance(clock_agent, 1)
    assert {:ok, [model: 2]} = ProviderCatalog.list_openrouter_models(cache_server: cache)

    assert {:ok, [model: 3]} =
             ProviderCatalog.list_openrouter_models(cache_server: cache, refresh: true)

    assert Agent.get(agent, & &1) == 3
  end

  test "failed warm refresh keeps the last catalog and backs off automatic retries" do
    {clock, clock_agent} = start_clock(0)
    agent = start_agent(:ok)

    {:ok, cache} =
      start_cache(
        fetch: fn _opts ->
          Agent.get_and_update(agent, fn
            :ok -> {{:ok, [model("warm/model")]}, :failed}
            :failed -> {{:error, String.duplicate("provider unavailable ", 30)}, :failed}
            :recovered -> {{:ok, [model("fresh/model")]}, :recovered}
          end)
        end,
        clock: clock,
        ttl_ms: 10,
        failure_backoff_ms: 30_000
      )

    assert {:ok, models} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    assert models == [model("warm/model")]
    advance(clock_agent, 10)

    assert {:ok, models} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    assert models == [model("warm/model")]
    assert byte_size(Cache.last_error(cache)) <= 240

    Agent.update(agent, fn _ -> :recovered end)

    assert {:ok, models} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    assert models == [model("warm/model")]

    assert {:ok, models} =
             ProviderCatalog.list_openrouter_models(cache_server: cache, refresh: true)

    assert models == [model("fresh/model")]
  end

  test "a successful recovery clears the previous failure backoff" do
    {clock, clock_agent} = start_clock(0)

    results =
      start_agent([{:ok, [model: 1]}, {:error, "outage"}, {:ok, [model: 2]}, {:ok, [model: 3]}])

    fetch = fn _opts ->
      Agent.get_and_update(results, fn [result | rest] -> {result, rest} end)
    end

    {:ok, cache} = start_cache(fetch: fetch, clock: clock, ttl_ms: 10)

    assert {:ok, [model: 1]} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    advance(clock_agent, 10)
    assert {:ok, [model: 1]} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    assert Cache.last_error(cache) == "outage"

    assert {:ok, [model: 2]} =
             ProviderCatalog.list_openrouter_models(cache_server: cache, refresh: true)

    assert Cache.last_error(cache) == nil
    ProviderCatalog.invalidate_cache(cache)
    assert {:ok, [model: 3]} = ProviderCatalog.list_openrouter_models(cache_server: cache)
  end

  test "cold failures stay errors during backoff, while explicit refresh retries" do
    {clock, _clock_agent} = start_clock(0)
    agent = start_agent(0)

    {:ok, cache} =
      start_cache(
        fetch: fn _opts ->
          Agent.get_and_update(agent, fn count ->
            count = count + 1

            if count == 1 do
              {{:error, "cold outage"}, count}
            else
              {{:ok, [model("recovered/model")]}, count}
            end
          end)
        end,
        clock: clock,
        failure_backoff_ms: 30_000
      )

    assert {:error, "cold outage"} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    assert {:error, "cold outage"} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    assert Agent.get(agent, & &1) == 1

    assert {:ok, models} =
             ProviderCatalog.list_openrouter_models(cache_server: cache, refresh: true)

    assert models == [model("recovered/model")]

    assert Agent.get(agent, & &1) == 2
  end

  test "automatic retries resume after failure backoff expires" do
    {clock, clock_agent} = start_clock(0)
    results = start_agent([{:error, "outage"}, {:ok, [model: 1]}])

    fetch = fn _opts ->
      Agent.get_and_update(results, fn [result | rest] -> {result, rest} end)
    end

    {:ok, cache} = start_cache(fetch: fetch, clock: clock, failure_backoff_ms: 30)

    assert {:error, "outage"} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    advance(clock_agent, 29)
    assert {:error, "outage"} = ProviderCatalog.list_openrouter_models(cache_server: cache)
    advance(clock_agent, 1)
    assert {:ok, [model: 1]} = ProviderCatalog.list_openrouter_models(cache_server: cache)
  end

  defp start_cache(opts) do
    start_supervised({Cache, Keyword.put(opts, :name, nil)})
  end

  defp model(id) do
    %{
      model_id: id,
      display_name: id,
      context_length: nil,
      capabilities: [],
      pricing: %{input_per_m: nil, output_per_m: nil},
      created: nil
    }
  end

  defp counted_fetch(agent) do
    fn _opts ->
      value = Agent.get_and_update(agent, fn value -> {value + 1, value + 1} end)
      {:ok, [model: value]}
    end
  end

  defp blocking_fetch(parent, agent, result) do
    fn _opts ->
      Agent.update(agent, &(&1 + 1))
      send(parent, {:fetch_started, self()})

      receive do
        :release_fetch -> {:ok, result}
      end
    end
  end

  defp start_clock(initial) do
    agent = start_agent(initial)
    {fn :millisecond -> Agent.get(agent, & &1) end, agent}
  end

  defp start_agent(initial),
    do: start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> initial end]}})

  defp advance(clock_agent, by), do: Agent.update(clock_agent, &(&1 + by))
end
