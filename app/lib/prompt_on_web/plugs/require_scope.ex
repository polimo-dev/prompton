defmodule PromptOnWeb.Plugs.RequireScope do
  @moduledoc """
  Public API scope check (plan.md §6.6). Used per controller, after `PromptOnWeb.Plugs.ApiKeyAuth`:

      plug PromptOnWeb.Plugs.RequireScope, :resolve   # config-fetch: GET /snapshot, POST /resolve
      plug PromptOnWeb.Plugs.RequireScope, :logs      # monitoring logs: POST /generations

  403 `{"error": {"code": "forbidden", ...}}` when the key lacks the scope; 401 when there is no key
  (a plug ordering mistake).
  """

  import Plug.Conn

  alias PromptOn.Projects.ApiKey
  alias PromptOnWeb.API.V1.ErrorJSON

  @scopes [:resolve, :logs]

  def init(scope) when scope in @scopes, do: scope

  def call(conn, scope) do
    case conn.assigns[:api_key] do
      %ApiKey{scopes: scopes} ->
        if scope in List.wrap(scopes),
          do: conn,
          else: reject(conn, 403, "forbidden", "API key lacks the #{scope} scope")

      _ ->
        reject(conn, 401, "unauthorized", "invalid or missing API key")
    end
  end

  defp reject(conn, status, code, message) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.put_view(json: ErrorJSON)
    |> Phoenix.Controller.render(:error, code: code, message: message)
    |> halt()
  end
end
