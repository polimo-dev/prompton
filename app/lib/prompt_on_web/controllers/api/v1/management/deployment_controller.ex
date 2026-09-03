defmodule PromptOnWeb.API.V1.Management.DeploymentController do
  @moduledoc """
  `/api/v1/orgs/:org/projects/:project/use-cases/:key/deployments` - **deployment pins** (ADR 0007
  revision 2026-09-01).

  | Request | Domain action |
  |---|---|
  | `GET  /deployments` | `Deployment.:current` (one live row per environment) |
  | `GET  /deployments?environment=staging` | `Deployment.:history` (its revisions, newest first) |
  | `POST /deployments` | `Deployment.:commit` |
  | `POST /deployments/rollback` | `Deployment.:rollback` |

  ## A revision is a pin, not a router

  A revision holds exactly four things - **one** model (`model_id`), `params`, `provider_options`,
  and a prompt **name -> version id** map (`prompt_pins`). There are no rules, conditions, weights,
  or A/B. **It is live the moment it is committed** (the highest revision is live), and a rollback
  is not a rewind but **committing a new revision** with the pins of a past one.

  ## The model can be given in two ways

  - `model_id` - the **UUID** of a catalog entry (the `id` from `GET /models`).
  - `model` - a provider string (`"anthropic/claude-sonnet-4"`). If it is in this project's catalog
    that entry is used; **if not, it is registered as an OpenRouter model**. This is the shortcut
    that lets onboarding (agent-first-spec §3.5, "pin v1 to the model already in use") skip a
    separate catalog registration.

  ## Omitting the pins means "every latest committed version as of now"

  Without `prompt_pins`, the **most recently committed version** of each prompt in this use case is
  pinned (the same default as Deploy in the use case hub). If no version has been committed at all
  it is a 400 - it means there is nothing to deploy, and a revision committed without pins would
  leave the app receiving `unresolved`. For a `kind: "embedding"` use case, having no pins is
  normal.

  A deployment revision has **no commit message field** (ADR 0007 - a revision is a pure pin). What
  changed and why is told by the prompt version's `message` and the revision number.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Catalog
  alias PromptOn.Catalog.Model
  alias PromptOn.Deployments
  alias PromptOn.Prompts
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.ModelSetup
  alias PromptOnWeb.API.V1.Management.Params
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  @commit_spec [
    {"params", :params, :map},
    {"provider_options", :provider_options, :map}
  ]

  def index(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, use_case} <- Scope.fetch_use_case(scope, params) do
      models = models_by_id(scope)

      case Map.get(params, "environment") do
        nil -> live(conn, project, use_case, scope, models)
        _slug -> history(conn, project, use_case, scope, params, models)
      end
    end
  end

  def create(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, use_case} <- Scope.fetch_use_case(scope, params),
         {:ok, environment} <- Scope.fetch_environment(conn, project, params),
         {:ok, model} <- fetch_model(scope, params),
         {:ok, pins} <- fetch_pins(scope, use_case, params),
         {:ok, attrs} <- Params.collect(params, @commit_spec),
         attrs =
           Map.merge(attrs, %{
             use_case_id: use_case.id,
             environment_id: environment.id,
             model_id: model.id,
             prompt_pins: pins
           }),
         {:ok, deployment} <- Deployments.commit_deployment(attrs, scope) do
      conn
      |> put_status(:created)
      |> json(JSON.deployment(deployment, environment.slug, model))
    end
  end

  def rollback(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, use_case} <- Scope.fetch_use_case(scope, params),
         {:ok, environment} <- Scope.fetch_environment(conn, project, params),
         {:ok, revision} <- fetch_revision(params),
         {:ok, source} <- fetch_source(scope, use_case, environment, revision),
         {:ok, deployment} <- Deployments.rollback_deployment(source.id, %{}, scope) do
      json(conn, deployment_json(deployment, environment.slug, models_by_id(scope)))
    end
  end

  # ---------------------------------------------------------------------------
  # Reads

  defp live(conn, project, use_case, scope, models) do
    deployments =
      conn
      |> Scope.environments(project)
      |> Enum.flat_map(fn environment ->
        case Deployments.current_deployment(use_case.id, environment.id, scope) do
          {:ok, nil} -> []
          {:ok, deployment} -> [deployment_json(deployment, environment.slug, models)]
          {:error, _error} -> []
        end
      end)

    json(conn, %{"deployments" => deployments})
  end

  defp history(conn, project, use_case, scope, params, models) do
    with {:ok, environment} <- Scope.fetch_environment(conn, project, params),
         {:ok, revisions} <- Deployments.deployment_history(use_case.id, environment.id, scope) do
      json(conn, %{
        "deployments" => Enum.map(revisions, &deployment_json(&1, environment.slug, models))
      })
    end
  end

  defp deployment_json(deployment, environment_slug, models),
    do: JSON.deployment(deployment, environment_slug, models[deployment.model_id])

  defp models_by_id(scope) do
    case Catalog.list_all_models(scope) do
      {:ok, models} -> Map.new(models, &{&1.id, &1})
      {:error, _error} -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Commit input

  defp fetch_model(scope, %{"model_id" => id}) when is_binary(id) and id != "" do
    case Catalog.get_model(id, scope) do
      {:ok, %Model{} = model} ->
        {:ok, model}

      _other ->
        {:error, {:not_found, "unknown model: #{id}", %{"model_id" => id}}}
    end
  end

  defp fetch_model(scope, %{"model" => model_id}) when is_binary(model_id) and model_id != "",
    do: ModelSetup.resolve(scope, model_id)

  defp fetch_model(_scope, _params),
    do:
      {:error,
       {:invalid_request,
        "model_id (a catalog model id) or model (a provider model string) is required"}}

  # Pins are `{"name": "<prompt version id>"}` - the name is the `prompt` value the app sends with
  # its request.
  defp fetch_pins(_scope, _use_case, %{"prompt_pins" => pins}) when is_map(pins) do
    if Enum.all?(pins, fn {name, id} -> is_binary(name) and is_binary(id) end) do
      {:ok, pins}
    else
      {:error, {:invalid_request, "prompt_pins must map prompt names to prompt version ids"}}
    end
  end

  defp fetch_pins(_scope, _use_case, %{"prompt_pins" => _other}),
    do: {:error, {:invalid_request, "prompt_pins must be an object"}}

  defp fetch_pins(_scope, %{kind: :embedding}, _params), do: {:ok, %{}}

  defp fetch_pins(scope, use_case, _params) do
    case latest_pins(scope, use_case) do
      pins when map_size(pins) > 0 ->
        {:ok, pins}

      _empty ->
        {:error,
         {:invalid_request,
          "this use case has no committed prompt version to pin — commit one first, " <>
            "or send prompt_pins explicitly", %{"use_case" => use_case.key}}}
    end
  end

  defp latest_pins(scope, use_case) do
    case Prompts.list_prompts(use_case.id, scope) do
      {:ok, prompts} -> prompts |> Enum.flat_map(&latest_pin(&1, scope)) |> Map.new()
      {:error, _error} -> %{}
    end
  end

  defp latest_pin(prompt, scope) do
    case Prompts.list_prompt_versions(prompt.id, scope) do
      {:ok, [latest | _rest]} -> [{prompt.name, latest.id}]
      _other -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Rollback input

  defp fetch_revision(%{"revision" => revision}) when is_integer(revision) and revision > 0,
    do: {:ok, revision}

  defp fetch_revision(_params),
    do: {:error, {:invalid_request, "revision must be a positive integer"}}

  defp fetch_source(scope, use_case, environment, revision) do
    with {:ok, revisions} <-
           Deployments.deployment_history(use_case.id, environment.id, scope) do
      case Enum.find(revisions, &(&1.revision == revision)) do
        nil ->
          {:error,
           {:not_found, "unknown revision: #{revision}",
            %{
              "revision" => revision,
              "environment" => environment.slug,
              "available_revisions" => Enum.map(revisions, & &1.revision)
            }}}

        deployment ->
          {:ok, deployment}
      end
    end
  end
end
