defmodule PromptOnWeb.API.V1.Management.ModelSetup do
  @moduledoc """
  Model registration for the management API - shared by `POST /projects/:project/models` and the
  `model` string of a deployment pin.

  ## Why registration is needed

  A deployment revision pins the **UUID of a catalog Model** (`Deployment.model_id`). So for a
  coding AI to pin v1 to the model the app was already using (`"anthropic/claude-sonnet-4"`), an
  entry has to exist in that project's catalog first. The `model` field of `POST /deployments`
  takes that step on its behalf - **find it if it exists, register it if not** (`resolve/2`).

  ## Filling in pricing (best-effort)

  For an OpenRouter model given without `pricing`, the display name, context length, capabilities,
  and **per-million-token rates** are copied from the public list (`PromptOnWeb.ProviderCatalog`,
  no authentication needed). Without rates, the cost aggregation of monitoring logs depends solely
  on the values the provider returned, and in a setup where the app calls the provider directly
  those are often absent - better to fill them in once during onboarding.

  Failures are **swallowed**: registration itself must succeed even if the provider list lookup is
  blocked or slow (nor is an unknown rate written as 0 - `ProviderCatalog` gives `nil` for values
  it does not know). If the caller gave no `display_name` and the lookup also fails, the raw
  `model_id` is used as the name.
  """

  alias PromptOn.Catalog
  alias PromptOn.Catalog.Model
  alias PromptOnWeb.ProviderCatalog

  @default_provider "openrouter"

  @doc "The `(provider, model_id)` entry in this project's catalog. `nil` if absent."
  @spec find(keyword(), String.t(), String.t()) :: Model.t() | nil
  def find(scope, provider, model_id) do
    case Catalog.get_model_by_provider_model(provider, model_id, scope) do
      {:ok, %Model{} = model} -> model
      _other -> nil
    end
  end

  @doc """
  OpenRouter model string -> catalog entry. **Finds it if it exists, registers it if not** (the
  `model` field of a deployment pin).
  """
  @spec resolve(keyword(), String.t()) :: {:ok, Model.t()} | {:error, term()}
  def resolve(scope, model_id) do
    case find(scope, @default_provider, model_id) do
      %Model{} = model -> {:ok, model}
      nil -> register(scope, model_id, %{})
    end
  end

  @doc """
  Catalog registration. `attrs` is what the caller gave; only the empty slots are filled from the
  provider list.
  """
  @spec register(keyword(), String.t(), map()) :: {:ok, Model.t()} | {:error, term()}
  def register(scope, model_id, attrs) do
    attrs =
      attrs
      |> Map.put(:model_id, model_id)
      |> Map.put_new(:provider, @default_provider)
      |> enrich(model_id)

    Catalog.register_model(attrs, scope)
  end

  @doc "The provider string (default `openrouter`)."
  @spec default_provider() :: String.t()
  def default_provider, do: @default_provider

  # ---------------------------------------------------------------------------
  # Filling empty slots from the provider list

  defp enrich(%{provider: provider} = attrs, model_id)
       when provider in [@default_provider, :openrouter] do
    case catalog_entry(model_id) do
      nil -> Map.put_new(attrs, :display_name, model_id)
      entry -> merge_entry(attrs, entry, model_id)
    end
  end

  defp enrich(attrs, model_id), do: Map.put_new(attrs, :display_name, model_id)

  defp merge_entry(attrs, entry, model_id) do
    attrs
    |> Map.put_new(:display_name, entry.display_name || model_id)
    |> put_new_present(:context_length, entry.context_length)
    |> put_new_present(:capabilities, present_list(entry.capabilities))
    |> put_new_present(:pricing, pricing(entry.pricing))
  end

  defp catalog_entry(model_id) do
    case ProviderCatalog.list_openrouter_models() do
      {:ok, models} -> Enum.find(models, &(&1.model_id == model_id))
      {:error, _reason} -> nil
    end
  rescue
    _error -> nil
  end

  defp put_new_present(attrs, _key, nil), do: attrs
  defp put_new_present(attrs, key, value), do: Map.put_new(attrs, key, value)

  defp present_list([]), do: nil
  defp present_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp present_list(_other), do: nil

  # Same unit as `pricing` on `PromptOn.Catalog.Model` (USD per million tokens). Unknown values are
  # left out.
  defp pricing(%{input_per_m: nil, output_per_m: nil}), do: nil

  defp pricing(%{} = rates) do
    %{}
    |> put_new_present("input_per_m", rates[:input_per_m])
    |> put_new_present("output_per_m", rates[:output_per_m])
    |> Map.merge(%{"currency" => "USD", "unit" => "token"})
  end

  defp pricing(_other), do: nil
end
