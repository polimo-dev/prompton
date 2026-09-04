defmodule PromptOnWeb.API.V1.Management.ModelController do
  @moduledoc """
  `/api/v1/orgs/:org/projects/:project/models` - the per-project model catalog (plan.md §5.4).

  | Request | Domain action |
  |---|---|
  | `GET  /models` | `Model.:read` (archived excluded - `deprecated` stays) |
  | `POST /models` | `Model.:register` (+ pricing/display name from the OpenRouter public list) |

  ## Why there are two names

  `id` is the UUID of this catalog entry, and that is what a deployment pin nails down. `model_id`
  is the **provider-side string** (`"anthropic/claude-sonnet-4"`) - it carries the same name in
  the schema-v4 use-case document and `POST /use-cases/:key/prompt`, so it is not renamed here
  either.

  The only required field is `model_id`. Without `display_name` it is taken from the OpenRouter
  public list, and if that has none either, `model_id` is used verbatim. Without `pricing`, the
  rates from the same list are copied in as USD per million tokens
  (`PromptOnWeb.API.V1.Management.ModelSetup`) - registration succeeds even if that fails.

  If the same `(provider, model_id)` already exists it is **409** with that entry in
  `details.model`.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Catalog
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.ModelSetup
  alias PromptOnWeb.API.V1.Management.Params
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  @register_spec [
    {"provider", :provider, :string},
    {"display_name", :display_name, :string},
    {"metadata", :metadata, :map},
    {"provider_options", :provider_options, :map},
    {"pricing", :pricing, :map},
    {"context_length", :context_length, :integer},
    {"capabilities", :capabilities, :strings},
    {"status", :status, :string}
  ]

  def index(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         {:ok, models} <- Catalog.list_all_models(Scope.scope(conn, project)) do
      models =
        models
        |> Enum.reject(& &1.archived_at)
        |> Enum.sort_by(&{to_string(&1.provider), &1.model_id})

      json(conn, %{"models" => Enum.map(models, &JSON.model/1)})
    end
  end

  def create(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, model_id} <- Params.required_string(params, "model_id"),
         {:ok, attrs} <- Params.collect(params, @register_spec),
         :ok <- ensure_available(scope, attrs, model_id),
         {:ok, model} <- ModelSetup.register(scope, model_id, attrs) do
      conn |> put_status(:created) |> json(JSON.model(model))
    end
  end

  # ---------------------------------------------------------------------------

  defp ensure_available(scope, attrs, model_id) do
    provider = Map.get(attrs, :provider) || ModelSetup.default_provider()

    case ModelSetup.find(scope, provider, model_id) do
      nil ->
        :ok

      model ->
        {:error,
         {:conflict, "#{provider} model #{model_id} is already registered",
          %{"model" => JSON.model(model)}}}
    end
  end
end
