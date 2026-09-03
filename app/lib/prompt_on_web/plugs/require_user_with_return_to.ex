defmodule PromptOnWeb.Plugs.RequireUserWithReturnTo do
  @moduledoc """
  Requires sign-in **and remembers where to return to**. Currently used by `/device` (CLI device
  approval).

  The `:live_user_required` hook in `PromptOnWeb.LiveUserAuth` also requires sign-in, but a LiveView
  hook cannot write to the session (there are no session writes on the socket) — so it cannot send
  the user back to where they were after signing in. This plug runs **in the HTTP request before
  the dead render**, so it can put `:return_to` in the session, and
  `PromptOnWeb.AuthController.success/4` reads it to send the user back right after sign-in.

  Including the query string is the point: the link the CLI hands out is `/device?code=ABCD-EFGH`,
  and losing the code means the person has to go back and look at the terminal again.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_session(:return_to, Phoenix.Controller.current_path(conn))
      |> Phoenix.Controller.redirect(to: "/sign-in")
      |> halt()
    end
  end
end
