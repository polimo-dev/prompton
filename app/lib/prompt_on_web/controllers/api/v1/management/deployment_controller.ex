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
  and the canonical default prompt version. The API prefers the scalar `prompt_version_id`; the
  stored and v4-compatible shape remains `prompt_pins: %{"default" => version_id}`. There are no
  rules, conditions, weights, A/B, or prompt-name selection. **It is live the moment it is
  committed** (the highest revision is live), and a rollback is not a rewind but **committing a new
  revision** with the contents of a past one.

  ## The model can be given in two ways

  - `model_id` - the **UUID** of a catalog entry (the `id` from `GET /models`).
  - `model` - a provider string (`"anthropic/claude-sonnet-4"`). If it is in this project's catalog
    that entry is used; **if not, it is registered as an OpenRouter model**. This is the shortcut
    that lets onboarding (agent-first-spec §3.5, "pin v1 to the model already in use") skip a
    separate catalog registration.

  ## Omitting the prompt version means "latest default as of now"

  Without `prompt_version_id` or default-only `prompt_pins`, the **most recently committed
  version** of the default prompt in this use case is pinned. If no version has been committed at
  all it is a 400 - it means there is nothing to deploy, and a revision committed without a default
  prompt would leave the app receiving `unresolved`.

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

  defp fetch_pins(_scope, _use_case, %{"prompt_version_id" => id} = params)
       when is_binary(id) and id != "" do
    case compatible_prompt_pins(params, id) do
      :ok -> {:ok, %{"default" => id}}
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  defp fetch_pins(_scope, _use_case, %{"prompt_version_id" => _other}),
    do: {:error, {:invalid_request, "prompt_version_id must be a non-empty string"}}

  # Backward-compatible v4 shape. Only the canonical default prompt remains authorable.
  defp fetch_pins(_scope, _use_case, %{"prompt_pins" => pins}) when is_map(pins) do
    cond do
      not Enum.all?(pins, fn {name, id} -> is_binary(name) and is_binary(id) end) ->
        {:error, {:invalid_request, "prompt_pins must map prompt names to prompt version ids"}}

      Map.keys(pins) == ["default"] ->
        {:ok, pins}

      true ->
        {:error, {:invalid_request, ~s|prompt_pins must contain only the "default" prompt|}}
    end
  end

  defp fetch_pins(_scope, _use_case, %{"prompt_pins" => _other}),
    do: {:error, {:invalid_request, "prompt_pins must be an object"}}

  defp fetch_pins(scope, use_case, _params) do
    case latest_pins(scope, use_case) do
      pins when map_size(pins) > 0 ->
        {:ok, pins}

      _empty ->
        {:error,
         {:invalid_request,
          "this use case has no committed default prompt version to pin — commit one first, " <>
            "or send prompt_version_id explicitly", %{"use_case" => use_case.key}}}
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
      {:ok, [latest | _rest]} -> [{"default", latest.id}]
      _other -> []
    end
  end

  defp compatible_prompt_pins(params, id) do
    case Map.fetch(params, "prompt_pins") do
      :error ->
        :ok

      {:ok, %{"default" => ^id} = pins} when map_size(pins) == 1 ->
        :ok

      {:ok, %{"default" => pinned_id} = pins} when map_size(pins) == 1 and is_binary(pinned_id) ->
        {:error, "prompt_version_id must match prompt_pins.default when both are provided"}

      {:ok, %{"default" => _pinned_id} = pins} when map_size(pins) == 1 ->
        {:error, "prompt_pins must map prompt names to prompt version ids"}

      {:ok, %{} = _pins} ->
        {:error, ~s|prompt_pins must contain only the "default" prompt|}

      {:ok, _other} ->
        {:error, "prompt_pins must be an object"}
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
