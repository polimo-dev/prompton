defmodule PromptOn.LLM do
  @moduledoc """
  The only path through which the server calls an LLM directly (plan.md §11.2). **Playground /
  Experiment / judge only** -- production calls are made by the app itself through the SDK
  (PromptOn is not a proxy).

  A behaviour (`complete/2`) plus a dispatcher. The adapter is swapped via
  `config :prompton, :llm_adapter` (default `PromptOn.LLM.OpenRouter`; the test environment uses
  `PromptOn.LLM.Fake`).

      {:ok, outcome} =
        PromptOn.LLM.complete(
          %{
            model: "anthropic/claude-sonnet-4",
            messages: [%{role: :user, content: "hello"}],
            params: %{"temperature" => 0.5, "max_tokens" => 1024},
            provider_options: %{"only" => ["Anthropic"], "allow_fallbacks" => false}
          },
          organization_id: organization.id
        )

  `opts` are interpreted by the adapter (OpenRouter: `:api_key`, `:organization_id`,
  `:receive_timeout`, `:req_options`). The returned outcome uses the same vocabulary as
  `PromptOnSDK.OpenRouter.outcome/1` (`stop_kind`, `cost_usd`, `model_used`) plus execution info
  (`latency_ms`) in a thin map -- Generation storage (§5.7) can take it as is.
  """

  @type request :: %{
          required(:model) => String.t(),
          optional(:messages) => [%{role: term(), content: term()}],
          optional(:params) => map(),
          optional(:provider_options) => map()
        }

  @type usage :: %{input_tokens: integer() | nil, output_tokens: integer() | nil}

  @type outcome :: %{
          content: String.t() | nil,
          tool_calls: list() | nil,
          finish_reason: String.t() | nil,
          stop_kind: atom(),
          usage: usage(),
          cost_usd: number() | nil,
          model_used: String.t() | nil,
          latency_ms: non_neg_integer(),
          raw: map()
        }

  @callback complete(request(), keyword()) :: {:ok, outcome()} | {:error, term()}

  @doc "One non-streaming call through the configured adapter."
  @spec complete(request(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def complete(request, opts \\ []), do: adapter().complete(request, opts)

  @doc "The current adapter module (`config :prompton, :llm_adapter`)."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:prompton, :llm_adapter, PromptOn.LLM.OpenRouter)
end
