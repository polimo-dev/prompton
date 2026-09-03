defmodule PromptOn.LLM.FakeTest do
  # Touches Application env (`:llm_fake_response`), so it runs synchronously.
  use ExUnit.Case, async: false

  alias PromptOn.LLM

  @request %{
    model: "anthropic/claude-sonnet-4",
    messages: [
      %{role: :system, content: "You are helpful."},
      %{role: :user, content: "hello"}
    ],
    params: %{"temperature" => 0.5}
  }

  setup do
    on_exit(&LLM.Fake.reset/0)
    :ok
  end

  test "the test environment dispatches PromptOn.LLM.complete/2 to the Fake" do
    assert LLM.adapter() == LLM.Fake
  end

  test "the default outcome is derived deterministically from the request" do
    assert {:ok, outcome} = LLM.complete(@request)
    assert {:ok, ^outcome} = LLM.complete(@request)

    assert outcome.content == "[fake:anthropic/claude-sonnet-4] You are helpful.\nhello"
    assert outcome.finish_reason == "stop"
    assert outcome.stop_kind == :stop
    assert outcome.cost_usd == 0.0
    assert outcome.model_used == "anthropic/claude-sonnet-4"
    assert outcome.tool_calls == nil
    assert outcome.usage.input_tokens > 0
    assert outcome.usage.output_tokens > 0
    assert outcome.latency_ms >= 0
    assert outcome.raw["fake"] == true
    assert outcome.raw["params"] == %{"temperature" => 0.5}
  end

  test "a request with no messages still works" do
    assert {:ok, outcome} = LLM.complete(%{model: "openai/gpt-5-mini"})
    assert outcome.content == "[fake:openai/gpt-5-mini] "
    assert outcome.model_used == "openai/gpt-5-mini"
  end

  test "a map response is merged over the default outcome" do
    LLM.Fake.set_response(%{content: "canned", stop_kind: :length, finish_reason: "length"})

    assert {:ok, outcome} = LLM.complete(@request)
    assert outcome.content == "canned"
    assert outcome.stop_kind == :length
    assert outcome.finish_reason == "length"
    # fields that were not overridden keep their defaults
    assert outcome.model_used == "anthropic/claude-sonnet-4"
    assert outcome.cost_usd == 0.0
  end

  test "a function response receives the request" do
    LLM.Fake.set_response(fn request ->
      {:ok, %{content: "echo:" <> request.model, stop_kind: :stop}}
    end)

    assert {:ok, %{content: "echo:anthropic/claude-sonnet-4"}} = LLM.complete(@request)
  end

  test "the function form can return an error" do
    LLM.Fake.set_response(fn _request -> {:error, :boom} end)
    assert {:error, :boom} = LLM.complete(@request)
  end

  test "an {:error, _} tuple is returned as-is" do
    LLM.Fake.set_response({:error, {:http_error, 429, %{}}})
    assert {:error, {:http_error, 429, %{}}} = LLM.complete(@request)
  end

  test "reset/0 restores the default outcome" do
    LLM.Fake.set_response(%{content: "canned"})
    assert {:ok, %{content: "canned"}} = LLM.complete(@request)

    LLM.Fake.reset()
    assert {:ok, outcome} = LLM.complete(@request)
    assert outcome.content =~ "[fake:"
  end

  test "it does not sleep unless :llm_fake_latency_ms is configured" do
    {micros, {:ok, _outcome}} = :timer.tc(fn -> LLM.complete(@request) end)
    assert micros < 50_000
  end
end
