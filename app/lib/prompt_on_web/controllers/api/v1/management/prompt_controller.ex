defmodule PromptOnWeb.API.V1.Management.PromptController do
  @moduledoc """
  `/api/v1/orgs/:org/projects/:project/use-cases/:key/prompts` - named prompt documents and their
  **immutable versions**.

  | Request | Domain action |
  |---|---|
  | `POST /prompts` | `Prompt.:open` |
  | `POST /prompts/:name/versions` | `PromptVersion.:commit` |

  ## The name is the selection axis

  One use case can have several prompts (`default`, `ko`), and the `prompt` value the app sends
  with its request is exactly this **name** (ADR 0007 revision - this is all there is to language
  branching). `:chat`/`:text` use cases are born with one `default` prompt when they are defined,
  so what gets opened here is usually the second name onward.

  ## A version is immutable from birth

  `POST .../versions` **commits** a new version - there is no action that edits an existing one.
  Committing alone makes nothing live: live happens when a deployment revision **pins** that
  version id (`POST .../deployments`). The request's `message` is the commit message and comes back
  as `message` in the response.

  `messages` belongs to `kind: "chat"` use cases and `text_template` to `kind: "text"`. On save the
  template is linted against the P0 whitelist (`PromptOnSDK.Template.lint/1`) and its variables are
  extracted into `detected_variables` - a lint failure is 400.
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
         {:ok, use_case} <- Scope.fetch_use_case(scope, params),
         {:ok, name} <- Params.required_string(params, "name"),
         {:ok, description} <- Params.optional_string(params, "description"),
         :ok <- ensure_available(scope, use_case, name),
         attrs = %{use_case_id: use_case.id, name: name, description: description},
         {:ok, prompt} <- Prompts.open_prompt(attrs, scope) do
      conn |> put_status(:created) |> json(JSON.prompt(prompt))
    end
  end

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
  Finds a prompt by name within a use case. `Prompt` has no lookup-by-name action - a use case has
  only a handful of prompts, so it is picked from the list.
  """
  @spec fetch_prompt(keyword(), PromptOn.Prompts.UseCase.t(), map()) ::
          {:ok, PromptOn.Prompts.Prompt.t()} | {:error, term()}
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

  defp ensure_available(scope, use_case, name) do
    case find_prompt(scope, use_case, name) do
      nil ->
        :ok

      prompt ->
        {:error,
         {:conflict, "a prompt named #{name} already exists in this use case",
          %{"prompt" => JSON.prompt(prompt)}}}
    end
  end
end
