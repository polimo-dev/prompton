defmodule PromptOn.LLM.Fake do
  @moduledoc """
  `PromptOn.LLM` adapter for tests and development. It never touches the network and returns an
  outcome **derived deterministically from the request**
  (`config :prompton, :llm_adapter, PromptOn.LLM.Fake` -- the test environment default).

  Default response: `content` is `"[fake:<model>] <the input messages joined>"`,
  `finish_reason "stop"`, `stop_kind :stop`, token counts are the input/output byte length / 4
  (minimum 1), `cost_usd 0.0`, `model_used` = the requested model.

  ## Overriding the response (`config :prompton, :llm_fake_response`)
  - `nil` -- the default response
  - `map` -- **shallow-merged** over the default response (`%{content: "hi", stop_kind: :length}`)
  - `fun/1` -- `(request -> {:ok, outcome} | {:error, term})`
  - `{:ok, outcome}` / `{:error, term}` -- returned as is

      PromptOn.LLM.Fake.set_response(%{content: "hello"})
      on_exit(&PromptOn.LLM.Fake.reset/0)

  ## Latency
  Sleeps only when `config :prompton, :llm_fake_latency_ms` is positive, and only for that long.
  **Default 0 -- tests have no reason to sleep.**
  """

  @behaviour PromptOn.LLM

  @impl PromptOn.LLM
  def complete(request, _opts) do
    maybe_sleep()

    case Application.get_env(:prompton, :llm_fake_response) do
      nil -> {:ok, default_outcome(request)}
      fun when is_function(fun, 1) -> fun.(request)
      {:ok, _outcome} = result -> result
      {:error, _reason} = result -> result
      overrides when is_map(overrides) -> {:ok, Map.merge(default_outcome(request), overrides)}
    end
  end

  @doc "Plants the response for subsequent calls (map / `fun/1` / `{:ok, _}` / `{:error, _}`)."
  @spec set_response(map() | (PromptOn.LLM.request() -> term()) | {:ok, map()} | {:error, term()}) ::
          :ok
  def set_response(response), do: Application.put_env(:prompton, :llm_fake_response, response)

  @doc "Removes the planted response (back to the default response)."
  @spec reset() :: :ok
  def reset do
    Application.delete_env(:prompton, :llm_fake_response)
    Application.delete_env(:prompton, :llm_fake_latency_ms)
    :ok
  end

  @doc "The default outcome derived from the request (the value before any override)."
  @spec default_outcome(PromptOn.LLM.request()) :: PromptOn.LLM.outcome()
  def default_outcome(request) do
    model = Map.get(request, :model)
    input = input_text(request)
    content = "[fake:#{model}] " <> input

    %{
      content: content,
      tool_calls: nil,
      finish_reason: "stop",
      stop_kind: :stop,
      usage: %{
        input_tokens: token_estimate(input),
        output_tokens: token_estimate(content)
      },
      cost_usd: 0.0,
      model_used: model,
      latency_ms: max(fake_latency_ms(), 1),
      raw: %{
        "fake" => true,
        "model" => model,
        "params" => Map.get(request, :params) || %{},
        "provider_options" => Map.get(request, :provider_options) || %{}
      }
    }
  end

  defp input_text(request) do
    request
    |> Map.get(:messages)
    |> List.wrap()
    |> Enum.map_join("\n", &content_of/1)
  end

  defp content_of(%{content: content}) when is_binary(content), do: content
  defp content_of(%{"content" => content}) when is_binary(content), do: content
  defp content_of(_message), do: ""

  # Roughly 4 bytes = 1 token. Deterministic is all we need.
  defp token_estimate(text), do: max(div(byte_size(text), 4), 1)

  defp maybe_sleep do
    case fake_latency_ms() do
      ms when ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  defp fake_latency_ms do
    case Application.get_env(:prompton, :llm_fake_latency_ms, 0) do
      ms when is_integer(ms) -> ms
      _ -> 0
    end
  end
end
