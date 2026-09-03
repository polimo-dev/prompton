defmodule PromptOnWeb.ProviderCatalog do
  @moduledoc """
  The **provider's public model list** read by "Import from provider" (the Import modal of the
  mockup `s_settings.jsx` ModelsScreen).

  Only OpenRouter is supported for now: `GET https://openrouter.ai/api/v1/models` needs no
  authentication, so the catalog can be filled even before a provider key is registered. The
  response is returned **narrowed** to `%{model_id, display_name, context_length, capabilities,
  pricing, created}`: only the values that go into the catalog should reach the screen, so the raw
  provider response does not linger whole in the LiveView socket.

  `pricing` is carried over in **the same unit** as `pricing` on `PromptOn.Catalog.Model` (dollars
  per million tokens). OpenRouter gives dollar strings **per token**, like
  `%{"prompt" => "0.000003", "completion" => "0.000015"}`, so it is multiplied by 1e6. An unknown
  value (missing key, not a number, the `"-1"` of dynamic pricing) is `nil`: writing an unknown
  price as 0 would make the screen lie that the model is "free".

  `created` is OpenRouter's `"created"`, the **Unix seconds** at which the model appeared in the
  list. It is the only value the picker's "Newest" sort looks at, so it is carried from here. When
  it is missing or does not read as a positive integer it is `nil` ("unknown"): writing an unknown
  time as `0` would make the model date from 1970 and the sort would lie.

  The URL is overridden with `config :prompton, :openrouter_models_url`, and the `Req` options (the
  test's `plug:` injection) with `config :prompton, :provider_catalog_req_options`; tests never hit
  real HTTP.

  Retries are off (`retry: false`) and it cuts off at 10 seconds. A failed list fetch must end as
  the screen's err flash, never kill the LiveView.
  """

  @default_url "https://openrouter.ai/api/v1/models"
  @receive_timeout 10_000

  @type pricing :: %{input_per_m: float() | nil, output_per_m: float() | nil}

  @type provider_model :: %{
          model_id: String.t(),
          display_name: String.t(),
          context_length: pos_integer() | nil,
          capabilities: [atom()],
          pricing: pricing(),
          created: pos_integer() | nil
        }

  @doc "OpenRouter's public model list. On failure `{:error, human-readable reason}`."
  @spec list_openrouter_models(keyword()) :: {:ok, [provider_model()]} | {:error, String.t()}
  def list_openrouter_models(opts \\ []) do
    request =
      [url: url(), receive_timeout: @receive_timeout, retry: false]
      |> Keyword.merge(Application.get_env(:prompton, :provider_catalog_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: %{"data" => data}}}
      when status in 200..299 and is_list(data) ->
        {:ok, data |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)}

      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:error, "unexpected response from openrouter"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "openrouter responded #{status}"}

      {:error, reason} ->
        {:error, "openrouter request failed (#{inspect(reason)})"}
    end
  end

  @doc "The OpenRouter model list URL."
  @spec url() :: String.t()
  def url, do: Application.get_env(:prompton, :openrouter_models_url, @default_url)

  defp normalize(%{"id" => id} = model) when is_binary(id) and id != "" do
    %{
      model_id: id,
      display_name: display_name(model, id),
      context_length: positive_integer(model["context_length"]),
      capabilities: capabilities(model),
      pricing: pricing(model["pricing"]),
      created: positive_integer(model["created"])
    }
  end

  defp normalize(_model), do: nil

  # Dollars per token → dollars per million tokens. The map always comes out even when both keys
  # are missing (a `nil` value means "unknown").
  defp pricing(%{} = pricing) do
    %{
      input_per_m: per_million(pricing["prompt"]),
      output_per_m: per_million(pricing["completion"])
    }
  end

  defp pricing(_pricing), do: %{input_per_m: nil, output_per_m: nil}

  @million Decimal.new(1_000_000)

  defp per_million(value) do
    case decimal(value) do
      nil ->
        nil

      d ->
        if Decimal.negative?(d), do: nil, else: d |> Decimal.mult(@million) |> Decimal.to_float()
    end
  end

  # Only accept a `coef` that is an integer: `"NaN"`/`"Infinity"` parse too, but multiplying them
  # or converting to float blows up.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: coef} = d, ""} when is_integer(coef) -> d
      _other -> nil
    end
  end

  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(_value), do: nil

  defp display_name(%{"name" => name}, _id) when is_binary(name) and name != "", do: name
  defp display_name(_model, id), do: id

  # Values like `context_length` and `created`, where **anything but a positive integer means
  # "unknown"**. The provider sometimes sends a string, so that is accepted too; everything else
  # (0, negative, not a number, missing key) is `nil`.
  defp positive_integer(n) when is_integer(n) and n > 0, do: n
  defp positive_integer(n) when is_float(n) and n > 0, do: trunc(n)

  defp positive_integer(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp positive_integer(_n), do: nil

  # The catalog's `capabilities` is a closed set:
  # `[:tools, :vision, :json_mode, :reasoning, :streaming]`. OpenRouter does not give these names
  # as is, so they are inferred from `supported_parameters` and `architecture`. Streaming support
  # is not in the list API, so it is not set (inventing a value that is not there would make the
  # catalog lie).
  defp capabilities(model) do
    params = model |> Map.get("supported_parameters") |> List.wrap() |> MapSet.new()

    modalities =
      model
      |> Map.get("architecture", %{})
      |> case do
        %{"input_modalities" => modalities} -> List.wrap(modalities)
        _ -> []
      end
      |> MapSet.new()

    []
    |> prepend(:tools, MapSet.member?(params, "tools"))
    |> prepend(
      :json_mode,
      MapSet.member?(params, "response_format") or MapSet.member?(params, "structured_outputs")
    )
    |> prepend(
      :reasoning,
      MapSet.member?(params, "reasoning") or MapSet.member?(params, "include_reasoning")
    )
    |> prepend(:vision, MapSet.member?(modalities, "image"))
    |> Enum.reverse()
  end

  defp prepend(list, value, true), do: [value | list]
  defp prepend(list, _value, false), do: list
end
