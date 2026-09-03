defmodule PromptOnWeb.API.V1.Management.UseCaseController do
  @moduledoc """
  `/api/v1/orgs/:org/projects/:project/use-cases` - "one LLM call site" of the app (plan.md §5.5).

  | Request | Domain action |
  |---|---|
  | `GET    /use-cases` | `UseCase.:active` |
  | `POST   /use-cases` | `UseCase.:define` (chat/text also open the `default` prompt, same transaction) |
  | `GET    /use-cases/:key` | `:by_key` + prompt/version summaries + live deployment per environment |
  | `PATCH  /use-cases/:key` | `:describe` / `:set_input_schema` / `:set_default_params` per fields sent |

  PATCH changes **only the fields sent**. All three may be mixed in one request (the three actions
  run in order), and sending only `name` runs just `:describe`. The domain action is split in three
  because each is a different contract - name/description are for people to read, `input_schema`
  is a declaration checked against the template variables, and `default_params` are the defaults
  that sit underneath a deployment pin's `params`.

  What the detail (`GET /use-cases/:key`) gives in one go: the use case itself, a summary of recent
  versions per prompt (up to 20, newest first), and **the live deployment per environment**. The
  point is that a coding AI should not have to fire several requests to learn "what is running
  right now".
  """

  use PromptOnWeb, :controller

  alias PromptOn.Catalog
  alias PromptOn.Deployments
  alias PromptOn.Prompts
  alias PromptOn.Prompts.UseCase
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.Params
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  # Number of version summaries carried in the detail (newest first). Not the whole history - "what
  # was committed recently".
  @version_limit 20

  @define_spec [
    {"name", :name, :string},
    {"kind", :kind, :string},
    {"description", :description, :string},
    {"input_schema", :input_schema, :input_schema},
    {"default_params", :default_params, :map},
    {"tags", :tags, :strings}
  ]

  @describe_spec [
    {"name", :name, :string},
    {"description", :description, :string},
    {"tags", :tags, :strings}
  ]

  @schema_spec [{"input_schema", :input_schema, :input_schema}]
  @defaults_spec [{"default_params", :default_params, :map}]

  def index(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         {:ok, use_cases} <- Prompts.list_use_cases(Scope.scope(conn, project)) do
      use_cases = Enum.sort_by(use_cases, & &1.key)
      json(conn, %{"use_cases" => Enum.map(use_cases, &JSON.use_case/1)})
    end
  end

  def create(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, key} <- Params.required_string(params, "key"),
         {:ok, attrs} <- Params.collect(params, @define_spec),
         :ok <- ensure_available(scope, key),
         attrs = attrs |> Map.put(:key, key) |> Map.put_new(:name, key),
         {:ok, use_case} <- Prompts.define_use_case(attrs, scope) do
      conn |> put_status(:created) |> json(JSON.use_case(use_case))
    end
  end

  def show(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, use_case} <- Scope.fetch_use_case(scope, params) do
      json(conn, detail(conn, project, use_case, scope))
    end
  end

  def update(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, use_case} <- Scope.fetch_use_case(scope, params),
         {:ok, describe} <- Params.collect(params, @describe_spec),
         {:ok, schema} <- Params.collect(params, @schema_spec),
         {:ok, defaults} <- Params.collect(params, @defaults_spec),
         {:ok, use_case} <- apply_change(use_case, describe, &Prompts.describe_use_case/3, scope),
         {:ok, use_case} <-
           apply_change(use_case, schema, &Prompts.set_use_case_input_schema/3, scope),
         {:ok, use_case} <-
           apply_change(use_case, defaults, &Prompts.set_use_case_default_params/3, scope) do
      json(conn, JSON.use_case(use_case))
    end
  end

  # ---------------------------------------------------------------------------

  defp apply_change(use_case, attrs, _fun, _scope) when map_size(attrs) == 0, do: {:ok, use_case}
  defp apply_change(use_case, attrs, fun, scope), do: fun.(use_case, attrs, scope)

  defp ensure_available(scope, key) do
    case Prompts.get_use_case_by_key(key, scope) do
      {:ok, %UseCase{} = use_case} ->
        {:error,
         {:conflict, "a use case with key #{key} already exists",
          %{"use_case" => JSON.use_case(use_case)}}}

      _other ->
        :ok
    end
  end

  # --- Detail ----------------------------------------------------------------

  defp detail(conn, project, use_case, scope) do
    use_case
    |> JSON.use_case()
    |> Map.put("prompts", prompts(use_case, scope))
    |> Map.put("deployments", deployments(conn, project, use_case, scope))
  end

  defp prompts(use_case, scope) do
    case Prompts.list_prompts(use_case.id, scope) do
      {:ok, prompts} ->
        prompts
        |> Enum.sort_by(& &1.name)
        |> Enum.map(&JSON.prompt(&1, versions(&1, scope)))

      {:error, _error} ->
        []
    end
  end

  defp versions(prompt, scope) do
    case Prompts.list_prompt_versions(prompt.id, scope) do
      {:ok, versions} -> Enum.take(versions, @version_limit)
      {:error, _error} -> []
    end
  end

  # **One live revision row** per environment. Environments without a deployment are left out.
  # Models are attached from a single read of the project catalog (a pin is a UUID, which neither a
  # person nor an AI can read on its own).
  defp deployments(conn, project, use_case, scope) do
    models = models_by_id(scope)

    conn
    |> Scope.environments(project)
    |> Enum.flat_map(fn environment ->
      case Deployments.current_deployment(use_case.id, environment.id, scope) do
        {:ok, nil} ->
          []

        {:ok, deployment} ->
          [JSON.deployment(deployment, environment.slug, models[deployment.model_id])]

        {:error, _error} ->
          []
      end
    end)
  end

  defp models_by_id(scope) do
    case Catalog.list_all_models(scope) do
      {:ok, models} -> Map.new(models, &{&1.id, &1})
      {:error, _error} -> %{}
    end
  end
end
