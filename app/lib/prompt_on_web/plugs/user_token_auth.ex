defmodule PromptOnWeb.Plugs.UserTokenAuth do
  @moduledoc """
  Management API authentication (agent-first-spec batch ③, `docs/management-api.md`).

  `Authorization: Bearer <CLI session token>` → `PromptOn.Accounts.CliSession.verify/1` →
  `Ash.PlugHelpers.set_actor(conn, user)` + `assign(:current_user, user)` +
  `assign(:bearer_token, raw)`.

  **The actor is a person.** Management keys (organization-level machine credentials) were deleted
  on 2026-09-02, and the CLI signs in as a user — so all this plug does is "find the user the token
  points at and install them as the actor", and what they may do is decided by each resource's
  **existing membership policies**, unchanged. Having no separate bypass layer is the point of this
  design.

  Like `ApiKeyAuth` (runtime keys) it **does not set a tenant**: a user belongs to several
  organizations and several projects, so the path picks the target — the organization by
  `PromptOnWeb.Plugs.ManagementOrgScope`, the project by
  `PromptOnWeb.API.V1.Management.Scope.fetch_project/2`, resolved on every request.

  `assign(:bearer_token, ...)` exists so that `POST /api/v1/sessions/revoke` (the CLI's logout) can
  revoke **this very token** — revocation needs the jti, and the jti is only in the raw token.

  Once authentication passes, the session's last-used time is stamped (`CliSession.touch/1` —
  written only once per 5 minutes). This is what the device list on the account screen relies on to
  show "used 3m ago".

  Failure response: 401 `{"error": {"code": "unauthorized", ...}}`. If any one of signature, expiry,
  issuer, revocation (jti), presence in storage, or purpose (`"cli"`) is off, it is the same 401 —
  it does not say which one was wrong.
  """

  import Plug.Conn

  alias PromptOn.Accounts.CliSession

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, raw} <- bearer(conn),
         {:ok, user, session} <- CliSession.authenticate(raw) do
      :ok = CliSession.touch(session)

      conn
      |> Ash.PlugHelpers.set_actor(user)
      |> assign(:current_user, user)
      |> assign(:bearer_token, raw)
      |> assign(:cli_session, session)
    else
      _other -> PromptOnWeb.API.V1.Management.Halt.unauthorized(conn)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] when byte_size(raw) > 8 -> {:ok, String.trim(raw)}
      ["bearer " <> raw] when byte_size(raw) > 8 -> {:ok, String.trim(raw)}
      _other -> {:error, :missing}
    end
  end
end
