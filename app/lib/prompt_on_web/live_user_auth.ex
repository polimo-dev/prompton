defmodule PromptOnWeb.LiveUserAuth do
  @moduledoc """
  The LiveView sign-in hook: `:live_user_required` sends the user to `/sign-in` when the session
  has no user. (The sign-in screen itself is not a LiveView but `PromptOnWeb.SignInController`.)
  """

  use PromptOnWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {PromptOnWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end
end
