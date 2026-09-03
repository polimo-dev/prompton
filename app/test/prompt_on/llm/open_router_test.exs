defmodule PromptOn.LLM.OpenRouterTest do
  # Touches Application env (`:openrouter_api_key`), so it runs synchronously.
  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures

  alias PromptOn.LLM.OpenRouter

  @request %{
    model: "anthropic/claude-sonnet-4",
    messages: [
      %{role: "system", content: "You are helpful."},
      %{role: "user", content: "hello"}
    ],
    params: %{"temperature" => 0.5, "max_tokens" => 1024, "top_p" => nil}
  }

  @body %{
    "id" => "gen-1",
    "model" => "anthropic/claude-sonnet-4",
    "provider" => "Anthropic",
    "choices" => [
      %{
        "finish_reason" => "end_turn",
        "message" => %{"content" => "Hello there", "tool_calls" => nil}
      }
    ],
    "usage" => %{
      "prompt_tokens" => 100,
      "completion_tokens" => 20,
      "cost" => 0.00123,
      "is_byok" => false
    }
  }

  setup do
    previous = Application.get_env(:prompton, :openrouter_api_key)
    Application.put_env(:prompton, :openrouter_api_key, "env-key")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:prompton, :openrouter_api_key)
      else
        Application.put_env(:prompton, :openrouter_api_key, previous)
      end
    end)

    :ok
  end

  # Plants a plug that forwards the request to the test process and returns `response`.
  defp stub(response, status \\ 200) do
    test_pid = self()

    Req.Test.stub(OpenRouter, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:llm_request,
         %{body: Jason.decode!(raw), headers: conn.req_headers, path: conn.request_path}}
      )

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(response)
    end)

    [req_options: [plug: {Req.Test, OpenRouter}]]
  end

  defp sent_request do
    assert_received {:llm_request, request}
    request
  end

  describe "request body" do
    test "carries model, messages, usage.include and the merged non-nil params" do
      assert {:ok, _outcome} = OpenRouter.complete(@request, stub(@body))

      %{body: body, headers: headers, path: path} = sent_request()

      assert path == "/api/v1/chat/completions"
      assert body["model"] == "anthropic/claude-sonnet-4"
      assert body["usage"] == %{"include" => true}

      assert body["messages"] == [
               %{"role" => "system", "content" => "You are helpful."},
               %{"role" => "user", "content" => "hello"}
             ]

      assert body["temperature"] == 0.5
      assert body["max_tokens"] == 1024
      # nil params are not sent
      refute Map.has_key?(body, "top_p")
      # without provider_options there is no "provider" key at all
      refute Map.has_key?(body, "provider")

      assert {"authorization", "Bearer env-key"} in headers
    end

    test "includes \"provider\" only when provider_options is non-empty" do
      request =
        Map.put(@request, :provider_options, %{"only" => ["Anthropic"], allow_fallbacks: false})

      assert {:ok, _outcome} = OpenRouter.complete(request, stub(@body))

      assert sent_request().body["provider"] == %{
               "only" => ["Anthropic"],
               "allow_fallbacks" => false
             }
    end

    test "an empty provider_options map is omitted" do
      assert {:ok, _} =
               OpenRouter.complete(Map.put(@request, :provider_options, %{}), stub(@body))

      refute Map.has_key?(sent_request().body, "provider")
    end

    test "atom-keyed params are stringified" do
      request = Map.put(@request, :params, %{temperature: 0.9, stop: ["\n\n"]})
      assert {:ok, _} = OpenRouter.complete(request, stub(@body))

      body = sent_request().body
      assert body["temperature"] == 0.9
      assert body["stop"] == ["\n\n"]
    end
  end

  describe "response parsing" do
    test "reshapes the SDK outcome and adds latency_ms" do
      assert {:ok, outcome} = OpenRouter.complete(@request, stub(@body))

      assert outcome.content == "Hello there"
      assert outcome.tool_calls == nil
      assert outcome.finish_reason == "end_turn"
      assert outcome.stop_kind == :stop
      assert outcome.usage == %{input_tokens: 100, output_tokens: 20}
      assert outcome.cost_usd == 0.00123
      assert outcome.model_used == "anthropic/claude-sonnet-4"
      assert is_integer(outcome.latency_ms) and outcome.latency_ms >= 0
      assert outcome.raw == @body
    end

    test "BYOK cost comes from cost_details.upstream_inference_cost" do
      body =
        put_in(@body["usage"], %{
          "prompt_tokens" => 10,
          "completion_tokens" => 2,
          "cost" => 0.0,
          "is_byok" => true,
          "cost_details" => %{"upstream_inference_cost" => 0.5}
        })

      assert {:ok, outcome} = OpenRouter.complete(@request, stub(body))
      assert outcome.cost_usd == 0.5
    end

    test "tool_calls map to stop_kind :tool_call" do
      calls = [%{"id" => "c1", "function" => %{"name" => "get_weather", "arguments" => "{}"}}]

      body =
        put_in(@body["choices"], [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{"content" => nil, "tool_calls" => calls}
          }
        ])

      assert {:ok, outcome} = OpenRouter.complete(@request, stub(body))
      assert outcome.stop_kind == :tool_call
      assert outcome.content == nil
      assert outcome.tool_calls == calls
    end

    test "missing usage yields nil tokens and nil cost" do
      body = Map.delete(@body, "usage")
      assert {:ok, outcome} = OpenRouter.complete(@request, stub(body))
      assert outcome.usage == %{input_tokens: nil, output_tokens: nil}
      assert outcome.cost_usd == nil
    end
  end

  describe "errors" do
    test "non-2xx becomes {:error, {:http_error, status, body, headers}}" do
      opts = stub(%{"error" => %{"message" => "rate limited"}}, 429)

      assert {:error, {:http_error, 429, body, headers}} = OpenRouter.complete(@request, opts)
      assert body["error"]["message"] == "rate limited"
      assert is_list(headers)
    end

    # For proxy mode to pass the upstream `Retry-After` through untouched, the adapter must carry
    # the headers.
    test "response headers ride along so Retry-After survives" do
      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "12")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "slow down"})
      end)

      assert {:error, {:http_error, 429, _body, headers}} =
               OpenRouter.complete(@request, req_options: [plug: {Req.Test, OpenRouter}])

      assert {"retry-after", "12"} in headers
    end

    test "a transport failure becomes {:error, {:request_failed, reason}}" do
      Req.Test.stub(OpenRouter, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:request_failed, _reason}} =
               OpenRouter.complete(@request, req_options: [plug: {Req.Test, OpenRouter}])
    end
  end

  describe "key resolution" do
    test "opts[:api_key] wins over everything" do
      opts = stub(@body) ++ [api_key: "explicit-key"]
      assert {:ok, _} = OpenRouter.complete(@request, opts)
      assert {"authorization", "Bearer explicit-key"} in sent_request().headers
    end

    test "falls back to the :openrouter_api_key application env" do
      assert {:ok, _} = OpenRouter.complete(@request, stub(@body))
      assert {"authorization", "Bearer env-key"} in sent_request().headers
    end

    test "returns {:error, :no_provider_key} when nothing is configured" do
      Application.delete_env(:prompton, :openrouter_api_key)
      assert {:error, :no_provider_key} = OpenRouter.complete(@request, stub(@body))
      refute_received {:llm_request, _}
    end

    test "an empty api_key/env value is ignored" do
      Application.put_env(:prompton, :openrouter_api_key, "")
      assert {:error, :no_provider_key} = OpenRouter.complete(@request, api_key: "")
    end

    test "uses the organization's newest active ProviderKey and touches last_used_at" do
      Application.delete_env(:prompton, :openrouter_api_key)
      org = organization_for(user_fixture())

      _old = provider_key_fixture(org, label: "old", secret: "sk-or-v1-oldoldoldoldoldold0001")
      new = provider_key_fixture(org, label: "new", secret: "sk-or-v1-newnewnewnewnewnew0002")

      opts = stub(@body) ++ [organization_id: org.id]
      assert {:ok, _} = OpenRouter.complete(@request, opts)

      assert {"authorization", "Bearer sk-or-v1-newnewnewnewnewnew0002"} in sent_request().headers

      reloaded = Ash.get!(PromptOn.Accounts.ProviderKey, new.id, actor: system_actor())
      assert %DateTime{} = reloaded.last_used_at
    end

    test "a revoked ProviderKey falls through to the application env" do
      org = organization_for(user_fixture())
      key = provider_key_fixture(org)
      {:ok, _} = PromptOn.Accounts.revoke_provider_key(key, actor: system_actor())

      opts = stub(@body) ++ [organization_id: org.id]
      assert {:ok, _} = OpenRouter.complete(@request, opts)
      assert {"authorization", "Bearer env-key"} in sent_request().headers
    end

    test "an organization with no ProviderKey and no env config errors" do
      Application.delete_env(:prompton, :openrouter_api_key)
      org = organization_for(user_fixture())

      assert {:error, :no_provider_key} =
               OpenRouter.complete(@request, stub(@body) ++ [organization_id: org.id])
    end

    test "a project's organization key serves that project's calls" do
      Application.delete_env(:prompton, :openrouter_api_key)
      project = project_fixture()
      _key = provider_key_fixture(project, secret: "sk-or-v1-byorg-0000000000001")

      opts = stub(@body) ++ [organization_id: project.organization_id]
      assert {:ok, _} = OpenRouter.complete(@request, opts)
      assert {"authorization", "Bearer sk-or-v1-byorg-0000000000001"} in sent_request().headers
    end
  end

  describe "base_url/0" do
    test "defaults to the OpenRouter API and honours configuration" do
      assert OpenRouter.base_url() == "https://openrouter.ai/api/v1"

      Application.put_env(:prompton, :openrouter_base_url, "http://localhost:4010/v1/")
      on_exit(fn -> Application.delete_env(:prompton, :openrouter_base_url) end)

      assert OpenRouter.base_url() == "http://localhost:4010/v1"
    end
  end
end
