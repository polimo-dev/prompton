defmodule PromptOnWeb.AuthController do
  @moduledoc """
  Sign-out - the end of the `DELETE /sign-out` that ash_authentication_phoenix's `sign_out_route`
  creates. (`GET /sign-out` is that route's `SignOutLive` confirmation page.)

  Sign-in is not here - ash_authentication's strategies and `auth_routes` are not used (`User` has
  no strategy), and email code sign-in is `PromptOnWeb.SignInController` seeding the session through
  `PromptOnWeb.UserSession.sign_in/2`. So `use AshAuthentication.Phoenix.Controller` is not done
  either - the one thing needed is `AshAuthentication.Phoenix.Controller.clear_session/2`, which
  clears the session and the token together.

  After sign-out, go to the session's `:return_to` (only when it is a same-site path,
  `UserSession.pop_return_to/2`), otherwise to `/`.
  """

  use PromptOnWeb, :controller

  alias PromptOnWeb.UserSession

  def sign_out(conn, _params) do
    {conn, return_to} = UserSession.pop_return_to(conn, ~p"/")

    conn
    |> AshAuthentication.Phoenix.Controller.clear_session(:prompton)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end
end
