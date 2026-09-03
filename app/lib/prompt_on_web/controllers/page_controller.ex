defmodule PromptOnWeb.PageController do
  @moduledoc """
  The root (`/`) entry point. It has no screen of its own - it only redirects based on sign-in
  state.

  - Signed out -> `/sign-in`
  - Signed in -> `/personal` (the current user's personal organization home = that organization's
    project list)

  There is no public landing page in this app - the separate repo `prompton-home` (a static site,
  prompton.ai / dev.prompton.ai) owns it, and the app lives at app.prompton.ai /
  app.dev.prompton.ai (2026-09-03). All the landing page links to is `/sign-in` and `/docs/agent`.

  Choosing a team organization is done inside the organization home - the root always lands on the
  personal organization.
  """
  use PromptOnWeb, :controller

  def home(conn, _params) do
    case conn.assigns[:current_user] do
      nil -> redirect(conn, to: ~p"/sign-in")
      # `personal` is a reserved segment, not a route (`PromptOn.Accounts.ReservedSlugs`).
      _user -> redirect(conn, to: ~p"/personal")
    end
  end
end
