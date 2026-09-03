defmodule PromptOnWeb.API.V1.Management.SessionController do
  @moduledoc """
  The CLI session itself - `GET /api/v1/me` and `POST /api/v1/sessions/revoke`.

  | Request | What it does |
  |---|---|
  | `GET  /me` | Who the token is + every organization that person can provision |
  | `POST /sessions/revoke` | Revokes **this one token** (`prompton logout`) |

  `/me` is what gets called right after `prompton login` and by `prompton whoami` - it has the same
  shape as the device approval response (`{"user": …, "organizations": […]}`), so the CLI needs
  only one parser.

  Revocation kills **this token only**. CLI sessions on other machines and browser logins stay
  alive - cleaning up one laptop must not cut off the logins elsewhere. Machines that are out of
  reach are disconnected one at a time under "Logged-in devices" on the account screen
  (`/account`), and the way to revoke everything is "Sign out everywhere" on the same screen
  (`PromptOn.Accounts.Sessions.revoke_all/2` - keeps only the browser session that clicked it).
  """

  use PromptOnWeb, :controller

  alias PromptOn.Accounts
  alias PromptOn.Accounts.CliSession
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  def me(conn, _params) do
    user = Scope.user(conn)

    with {:ok, organizations} <- Accounts.list_organizations_for(user.id, actor: user) do
      json(conn, %{
        "user" => JSON.user(user),
        "organizations" => Enum.map(organizations, &JSON.organization/1)
      })
    end
  end

  def revoke(conn, _params) do
    case CliSession.revoke(conn.assigns.bearer_token) do
      :ok -> json(conn, %{"revoked" => true})
      {:error, _error} -> {:error, {:invalid_request, "could not revoke this session"}}
    end
  end
end
