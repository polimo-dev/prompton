defmodule PromptOnWeb.API.V1.Management.Halt do
  @moduledoc """
  The two ways a pipeline plug **ends** a request - 401 and 404. They use the same envelope as the
  controllers' `PromptOnWeb.API.V1.FallbackController`, but a plug cannot go through
  `action_fallback` (it runs before route dispatch), so the rendering is written out once here.
  """

  import Plug.Conn

  alias PromptOnWeb.API.V1.ErrorJSON

  @doc "401 - the token is missing, wrong, expired, revoked, or not a CLI session."
  @spec unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  def unauthorized(conn),
    do: send_error(conn, :unauthorized, "unauthorized", "invalid or missing CLI session token")

  @doc """
  404 - an organization this user is not a member of (or that does not exist). **Not 403**: the
  rule of this API is that other people's organizations are not even visible to exist
  (`docs/management-api.md` §1).
  """
  @spec not_found(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  def not_found(conn, message, details \\ %{}),
    do: send_error(conn, :not_found, "not_found", message, details)

  defp send_error(conn, status, code, message, details \\ %{}) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.put_view(json: ErrorJSON)
    |> Phoenix.Controller.render(:error, code: code, message: message, details: details)
    |> halt()
  end
end
