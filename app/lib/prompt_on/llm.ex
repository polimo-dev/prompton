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
  `PromptOnSDK.Result.from_openai/1` (`stop_kind`, `cost_usd`, `model_used`) plus execution info
  (`latency_ms`) in a thin map -- Generation storage (§5.7) can take it as is.
  """

  require Logger

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

  @doc """
  One non-streaming call through the configured adapter.

  Draft and Evaluation callers attach `usage: %{use_case: use_case, operation: kind}`. A
  successful provider outcome is recorded before the caller parses or applies it, so retries,
  discarded drafts and invalid model answers still contribute their actual cost. Arena already
  records Generations and must not attach this option. A missing provider cost remains unknown.
  """
  @spec complete(request(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def complete(request, opts \\ []) do
    {usage, adapter_opts} = Keyword.pop(opts, :usage)
    started_at = DateTime.utc_now()

    with {:ok, outcome} <- adapter().complete(request, adapter_opts),
         :ok <- record_usage(usage, request, outcome, started_at) do
      {:ok, outcome}
    end
  end

  defp record_usage(nil, _request, _outcome, _started_at), do: :ok

  defp record_usage(
         %{use_case: %PromptOn.Prompts.UseCase{} = use_case, operation: operation},
         request,
         outcome,
         started_at
       ) do
    usage = Map.get(outcome, :usage) || %{}

    attrs = %{
      use_case_key: use_case.key,
      operation: operation,
      model: outcome[:model_used] || request.model,
      input_tokens: usage[:input_tokens],
      output_tokens: usage[:output_tokens],
      cost_usd: outcome[:cost_usd],
      started_at: started_at
    }

    case PromptOn.Observability.record_ai_usage(attrs,
           tenant: use_case.project_id,
           actor: PromptOn.SystemActor.new()
         ) do
      {:ok, _usage} -> :ok
      {:error, _error} -> usage_failure(use_case, operation, outcome)
    end
  rescue
    _error -> usage_failure(use_case, operation, outcome)
  end

  # The provider has already charged. Never repeat the model call because bookkeeping failed,
  # and never log the returned body or the database exception (both may contain raw content).
  defp usage_failure(use_case, operation, outcome) do
    Logger.error("AI usage recording failed",
      project_id: use_case.project_id,
      use_case_key: use_case.key,
      operation: operation,
      cost_usd: outcome[:cost_usd]
    )

    :ok
  end

  @doc "The current adapter module (`config :prompton, :llm_adapter`)."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:prompton, :llm_adapter, PromptOn.LLM.OpenRouter)
end
