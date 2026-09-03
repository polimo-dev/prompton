defmodule PromptOnWeb.API.V1.RequestEnvironment do
  @moduledoc """
  **Picks the environment** for a public API request (2026-09-01).

  An ApiKey is project-level (the environment binding was removed), so the request decides which
  environment's configuration to read: the `environment` parameter (a slug, default
  `"production"`) or a query string of the same name. The lookup stays within the key's tenant, so
  other projects' environments are not visible.

  **The hot path does not touch the DB**: `PromptOnWeb.Plugs.ApiKeyAuth` reads the project on every
  request and loads `project.environments` along with it, so here the slug is only looked up in
  that list. Only calls where the list was not loaded (direct internal calls, tests) do one
  defensive query.

  Failures use the envelope as-is - a shape violation is 400, a missing/archived environment is 404.
  """

  alias PromptOn.Projects
  alias PromptOn.Projects.Environment

  @default_environment "production"

  @doc "The default environment slug."
  @spec default() :: String.t()
  def default, do: @default_environment

  @doc """
  Finds the environment the request chose within the project of `conn.assigns.api_key`.
  `"production"` when `params["environment"]` is absent.
  """
  @spec fetch(Plug.Conn.t(), map()) :: {:ok, Environment.t()} | {:error, term()}
  def fetch(conn, params) do
    api_key = conn.assigns.api_key

    with {:ok, slug} <- slug(params) do
      case find(api_key, slug) do
        %Environment{archived_at: nil} = environment ->
          {:ok, environment}

        _ ->
          {:error, {:not_found, "unknown environment: #{slug}", %{"environment" => slug}}}
      end
    end
  end

  # The list the plug loaded comes first (zero queries).
  defp find(%{project: %{environments: environments}}, slug) when is_list(environments),
    do: Enum.find(environments, &(&1.slug == slug))

  defp find(api_key, slug) do
    case Projects.get_environment_by_slug(slug, actor: api_key, tenant: api_key.project_id) do
      {:ok, %Environment{} = environment} -> environment
      _ -> nil
    end
  end

  defp slug(params) do
    case Map.get(params, "environment") do
      nil -> {:ok, @default_environment}
      slug when is_binary(slug) and slug != "" -> {:ok, slug}
      _ -> {:error, {:invalid_request, "environment must be a non-empty string"}}
    end
  end
end
