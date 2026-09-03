defmodule PromptOnWeb.API.V1.Management.ApiKeyController do
  @moduledoc """
  `/api/v1/orgs/:org/projects/:project/api-keys` - the **runtime** keys an app uses
  (`PromptOn.Projects.ApiKey`).

  | Request | Domain action |
  |---|---|
  | `GET  /api-keys` | `ApiKey.:for_project` (revoked keys excluded) |
  | `POST /api-keys` | `ApiKey.:issue` |

  This is the last step of onboarding (agent-first-spec §3.5): once the coding AI has finished
  provisioning, this is where it gets the key to put into the app's environment variables. This key
  is a **different layer** from the CLI session token - it is bound to a single project, its scopes
  are only `resolve` (config-fetch) and `logs` (monitoring logs), and it cannot provision.

  **The raw key appears exactly once, in the `key` of the issue response.** Only the sha256 hash is
  stored, so it cannot be seen again in the listing - only `key_prefix` remains. Keys are not bound
  to an environment (2026-09-01), so issuing has no environment field - the app picks the
  environment with a request parameter.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Projects
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.Params
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  @default_name "CLI key"

  def index(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         {:ok, keys} <- Projects.list_api_keys(project.id, actor: Scope.user(conn)) do
      keys =
        keys
        |> Enum.reject(& &1.revoked_at)
        |> Enum.sort_by(& &1.inserted_at, DateTime)

      json(conn, %{"api_keys" => Enum.map(keys, &JSON.api_key/1)})
    end
  end

  def create(conn, params) do
    with {:ok, project} <- Scope.fetch_project(conn, params),
         {:ok, name} <- Params.optional_string(params, "name"),
         {:ok, scopes} <- fetch_scopes(params),
         attrs = attrs(project, name, scopes),
         {:ok, key} <- Projects.issue_api_key(attrs, actor: Scope.user(conn)) do
      raw = Ash.Resource.get_metadata(key, :raw_key)

      conn |> put_status(:created) |> json(JSON.api_key(key, raw))
    end
  end

  # ---------------------------------------------------------------------------

  defp attrs(project, name, scopes) do
    attrs = %{project_id: project.id, name: blank_to_default(name)}

    if scopes, do: Map.put(attrs, :scopes, scopes), else: attrs
  end

  defp blank_to_default(nil), do: @default_name

  defp blank_to_default(name) do
    case String.trim(name) do
      "" -> @default_name
      trimmed -> trimmed
    end
  end

  # The meaning of the values (`resolve`/`logs`) is enforced by the `one_of` on `ApiKey.scopes` -
  # only the shape is checked here.
  defp fetch_scopes(params) do
    case Map.get(params, "scopes") do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, {:invalid_request, "scopes must be an array of strings"}}

      _other ->
        {:error, {:invalid_request, "scopes must be an array of strings"}}
    end
  end
end
