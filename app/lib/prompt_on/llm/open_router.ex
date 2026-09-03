defmodule PromptOn.LLM.OpenRouter do
  @moduledoc """
  OpenRouter (OpenAI-compatible `chat/completions`) adapter for `PromptOn.LLM` -- calls it directly
  with `Req`.

  For "experiment result = production result" to hold, the server must send the **same body** the
  SDK sends from the app and read the **same fields** (plan.md §11.3). So response parsing reuses
  `PromptOnSDK.OpenRouter.outcome/1` (= `effective_cost/2` + `StopKind.normalize/1`) as is, and the
  request body is assembled by the same rules:

      %{"model" => …, "messages" => […],
        "usage" => %{"include" => true},   # else cost/cost_details/is_byok are missing
        …params…,                          # keys with nil values are dropped
        "provider" => %{…}}                # only when provider_options is non-empty

  Why assemble straight from the request map instead of building a `Resolution` struct: the
  Playground also runs ad-hoc (unsaved draft) columns.

  ## Options (`opts`)
  - `:api_key` -- a raw key given directly (first in key resolution)
  - `:organization_id` -- use this organization's `ProviderKey` (BYOK) (second)
  - `:receive_timeout` -- default `120_000`ms
  - `:req_options` -- overrides `Req` options (for injecting `plug:` in tests)

  ## Key resolution
  See `resolve_key/1`. `opts[:api_key]` → the organization's `ProviderKey` (openrouter, newest
  non-revoked) → the app setting `:openrouter_api_key` (`PTN_OPENROUTER_API_KEY`) →
  `{:error, :no_provider_key}`.

  ## Errors
  - Non-2xx → `{:error, {:http_error, status, body, headers}}` -- `headers` is
    `[{"retry-after", "12"}, …]` (lowercase keys). Callers need the headers to read the upstream
    429/503 `Retry-After`, so **the 4-tuple is canonical**. The 3-tuple
    `{:http_error, status, body}` is still treated as valid input (the Fake adapter and existing
    call sites).
  - 2xx but not a JSON map → `{:error, {:invalid_response, body}}`
  - Transport failure → `{:error, {:request_failed, reason}}`

  Retries are off (`retry: false`) -- for a non-streaming LLM POST, a retry is a duplicate charge.
  """

  @behaviour PromptOn.LLM

  alias PromptOn.Accounts
  alias PromptOnSDK.{OpenRouter, Params, StopKind}

  require Logger

  @default_base_url "https://openrouter.ai/api/v1"
  @default_receive_timeout 120_000

  @impl PromptOn.LLM
  def complete(request, opts) do
    with {:ok, api_key} <- resolve_key(opts) do
      body = request_body(request)
      started = System.monotonic_time()

      case Req.request(req_options(body, api_key, opts)) do
        {:ok, %Req.Response{status: status, body: response}}
        when status in 200..299 and is_map(response) ->
          {:ok, outcome(response, elapsed_ms(started))}

        {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
          {:error, {:invalid_response, response}}

        {:ok, %Req.Response{status: status, body: response, headers: headers}} ->
          {:error, {:http_error, status, response, response_headers(headers)}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc "OpenRouter API base URL (`config :prompton, :openrouter_base_url`)."
  @spec base_url() :: String.t()
  def base_url do
    :prompton
    |> Application.get_env(:openrouter_base_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  @doc false
  @spec request_body(PromptOn.LLM.request()) :: map()
  def request_body(request) do
    params =
      request
      |> Map.get(:params)
      |> Params.stringify_keys()
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    %{
      "model" => Map.fetch!(request, :model),
      "messages" => List.wrap(Map.get(request, :messages)),
      "usage" => %{"include" => true}
    }
    |> Map.merge(params)
    |> put_provider(Map.get(request, :provider_options))
  end

  defp put_provider(body, options) when is_map(options) and map_size(options) > 0,
    do: Map.put(body, "provider", Params.stringify_keys(options))

  defp put_provider(body, _options), do: body

  defp req_options(body, api_key, opts) do
    [
      method: :post,
      url: base_url() <> "/chat/completions",
      headers: [{"authorization", "Bearer " <> api_key}],
      json: body,
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
      retry: false
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
  end

  # Keep only the fields the server uses from the `PromptOnSDK.OpenRouter.outcome/1` result and add
  # `latency_ms`. Re-normalizing `stop_kind` is idempotent (`StopKind`), so it is safe.
  defp outcome(response, latency_ms) do
    parsed = OpenRouter.outcome(response)

    %{
      content: parsed.content,
      tool_calls: parsed.tool_calls,
      finish_reason: parsed.finish_reason,
      stop_kind: StopKind.normalize(parsed.stop_kind),
      usage: %{
        input_tokens: parsed.usage.input_tokens,
        output_tokens: parsed.usage.output_tokens
      },
      cost_usd: parsed.cost_usd,
      model_used: parsed.model_used,
      latency_ms: latency_ms,
      raw: response
    }
  end

  # `Req.Response.headers` is a `%{"retry-after" => ["12"]}` map -- flatten the single-value lists
  # into `[{"retry-after", "12"}]` (Req has already lowercased the keys).
  defp response_headers(headers) when is_map(headers) do
    Enum.map(headers, fn
      {name, [value | _]} -> {name, to_string(value)}
      {name, value} -> {name, to_string(value)}
    end)
  end

  defp response_headers(headers) when is_list(headers), do: headers
  defp response_headers(_headers), do: []

  defp elapsed_ms(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
  end

  # Key resolution order (the first hit wins):
  #   1. `opts[:api_key]` -- the raw key from the caller (the arena's "use this key just this once")
  #   2. the newest non-revoked openrouter `ProviderKey` of the `opts[:organization_id]`
  #      organization (cloak `decrypt_by_default []`, so `load: [:secret]` must be explicit to get
  #      the raw value)
  #   3. the app setting `:openrouter_api_key` (= `PTN_OPENROUTER_API_KEY`) -- the fallback before a
  #      key is registered in the UI (plan.md §5.4)
  #   4. otherwise `{:error, :no_provider_key}`
  defp resolve_key(opts) do
    with :error <- key_from_opts(opts),
         :error <- key_from_provider_key(Keyword.get(opts, :organization_id)),
         :error <- key_from_app_env() do
      {:error, :no_provider_key}
    end
  end

  defp key_from_opts(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> :error
    end
  end

  defp key_from_provider_key(organization_id) when is_binary(organization_id) do
    actor = PromptOn.SystemActor.new()

    case Accounts.active_provider_key(organization_id, :openrouter,
           actor: actor,
           load: [:secret]
         ) do
      {:ok, %{secret: secret} = provider_key} when is_binary(secret) and secret != "" ->
        touch(provider_key, actor)
        {:ok, secret}

      _ ->
        :error
    end
  end

  defp key_from_provider_key(_organization_id), do: :error

  defp key_from_app_env do
    case Application.get_env(:prompton, :openrouter_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> :error
    end
  end

  # best-effort -- a failed `last_used_at` update must not block the LLM call.
  defp touch(provider_key, actor) do
    case Accounts.touch_provider_key(provider_key, %{}, actor: actor) do
      {:ok, _record} -> :ok
      {:error, error} -> log_touch_failure(error)
    end
  rescue
    error -> log_touch_failure(error)
  end

  defp log_touch_failure(error) do
    Logger.debug(fn -> "provider key touch_last_used failed: #{inspect(error)}" end)
    :ok
  end
end
