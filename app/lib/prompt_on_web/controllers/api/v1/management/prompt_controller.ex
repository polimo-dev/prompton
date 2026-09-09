defmodule PromptOnWeb.API.V1.Management.PromptController do
  @moduledoc """
  `/api/v1/orgs/:org/projects/:project/use-cases/:key/prompt/versions` - commits immutable
  versions of the canonical default prompt.

  | Request | Domain action |
  |---|---|
  | `POST /prompt/versions` | `PromptVersion.:commit` for `default` |
  | `POST /prompts/default/versions` | compatibility alias for `POST /prompt/versions` |
  | `POST /prompts` / non-default names | rejected |

  ## One authorable prompt

  Active management writes only the `default` prompt. The plural and name-based routes remain for
  compatibility: they either accept the `default` alias or return an explicit error for
  non-default prompt names. Historical non-default prompt rows remain readable for old logs and
  consolidation, but new versions cannot be committed for them.

  ## A version is immutable from birth

  `POST .../versions` **commits** a new version - there is no action that edits an existing one.
  Committing alone makes nothing live: live happens when a deployment revision **pins** that
  version id (`POST .../deployments`). The request's `message` is the commit message and comes back
  as `message` in the response.

  `messages` is the active prompt content. `text_template` stays in the response shape for
  historical versions, but new commits reject it. On save the template is linted against the P0
  whitelist (`PromptOnSDK.Template.lint/1`) and its variables are extracted into
  `detected_variables` - a lint failure is 400.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Prompts
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.Params
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  @commit_spec [
    {"messages", :messages, :messages},
    {"text_template", :text_template, :string},
    {"engine", :engine, :string},
    {"message", :commit_message, :string}
  ]

  def create(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, _use_case} <- Scope.fetch_use_case(scope, params) do
      {:error, {:invalid_request, "use cases support only the default prompt"}}
    end
  end

  def commit_default(conn, params), do: commit(conn, Map.put(params, "name", "default"))

  def commit(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         scope = Scope.scope(conn, project),
         {:ok, use_case} <- Scope.fetch_use_case(scope, params),
         {:ok, prompt} <- fetch_prompt(scope, use_case, params),
         {:ok, attrs} <- Params.collect(params, @commit_spec),
         attrs = Map.put(attrs, :prompt_id, prompt.id),
         {:ok, version} <- Prompts.commit_prompt_version(attrs, scope) do
      conn |> put_status(:created) |> json(JSON.prompt_version(version))
    end
  end

  # ---------------------------------------------------------------------------

  @doc """
  Finds the canonical default prompt within a use case. Non-default names are rejected before the
  lookup because active authoring no longer has prompt selection.
  """
  @spec fetch_prompt(keyword(), PromptOn.Prompts.UseCase.t(), map()) ::
          {:ok, PromptOn.Prompts.Prompt.t()} | {:error, term()}
  def fetch_prompt(_scope, _use_case, %{"name" => name})
      when is_binary(name) and name != "default" do
    {:error, {:invalid_request, ~s|only the default prompt is supported|, %{"prompt" => name}}}
  end

  def fetch_prompt(scope, use_case, %{"name" => name}) when is_binary(name) and name != "" do
    case find_prompt(scope, use_case, name) do
      nil ->
        {:error,
         {:not_found, "unknown prompt: #{name}",
          %{"prompt" => name, "prompt_names" => prompt_names(scope, use_case)}}}

      prompt ->
        {:ok, prompt}
    end
  end

  def fetch_prompt(_scope, _use_case, _params),
    do: {:error, {:invalid_request, "prompt name is required"}}

  defp find_prompt(scope, use_case, name) do
    case Prompts.list_prompts(use_case.id, scope) do
      {:ok, prompts} -> Enum.find(prompts, &(&1.name == name))
      {:error, _error} -> nil
    end
  end

  defp prompt_names(scope, use_case) do
    case Prompts.list_prompts(use_case.id, scope) do
      {:ok, prompts} -> prompts |> Enum.map(& &1.name) |> Enum.sort()
      {:error, _error} -> []
    end
  end
end
