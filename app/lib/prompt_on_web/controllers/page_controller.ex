defmodule PromptOnWeb.PageController do
  @moduledoc """
  The root (`/`) entry point. It has no screen of its own - it only redirects based on sign-in
  state.

  - Signed out -> `/sign-in`
  - Signed in -> personal organization, otherwise the newest accessible organization
  - Signed in without organizations -> `/account`

  There is no public landing page in this app - the separate repo `prompton-home` (a static site,
  prompton.ai / dev.prompton.ai) owns it, and the app lives at app.prompton.ai /
  app.dev.prompton.ai (2026-09-03). All the landing page links to is `/sign-in` and `/docs/agent`.

  Converting a personal organization does not require creating a replacement to keep signing in.
  """
  use PromptOnWeb, :controller

  def home(conn, _params) do
    case conn.assigns[:current_user] do
      nil -> redirect(conn, to: ~p"/sign-in")
      user -> redirect(conn, to: PromptOnWeb.LiveProjectScope.home_path(user))
    end
  end
end
