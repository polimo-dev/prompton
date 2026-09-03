defmodule PromptOn.Accounts.ReservedSlugs do
  @moduledoc """
  The **single home** of slug reserved words: two sets, organization slugs (`reserved?/1`) and
  project slugs (`project_reserved?/1`).

  With URLs of the form `/{org_slug}/{project_slug}/...`, organization slugs share a namespace
  with the router's **static top-level paths**. Without reserved words, creating an organization
  named `/settings` would shadow that route.

  ⚠️ **Must stay in sync with `PromptOnWeb.Router`**: when you add a static top-level path
  (`scope "/..."`, `live "/..."`, or a path produced by a macro such as `oban_dashboard`,
  `live_dashboard`, or `sign_out_route`) or a `PromptOnWeb.static_paths/0` entry, add it to this
  list too. `test/prompt_on/accounts/reserved_slugs_test.exs` scans the router to enforce this
  sync (in one direction only: a reserved word without a route is allowed; only a route without a
  reserved word is blocked).

  `personal` is not a route but a **reserved segment**: `/personal` resolves to the current
  user's personal organization.

  A project slug is the second segment of `/{org_slug}/{project_slug}`, so it shares a namespace
  with the **static paths of the organization scope** (`/{org}/settings`, `/{org}/members`, …).
  See `project_reserved?/1` for the list.
  """

  # Router static paths: account api dev device docs health oban sign-in sign-out
  # Static assets (`PromptOnWeb.static_paths/0`): assets fonts images favicon.ico robots.txt
  # The rest pre-emptively block names an organization must not take even without a route
  # (admin/register/settings/use-cases/js/css/p/projects …).
  @reserved ~w(
    personal
    account
    admin
    api
    assets
    css
    dev
    device
    docs
    favicon
    favicon.ico
    fonts
    live
    health
    images
    js
    oban
    p
    projects
    register
    robots
    robots.txt
    settings
    sign-in
    sign-out
    use-cases
  )

  # The static second segment of the organization scope (`/{org_slug}/...`). If a project slug is
  # one of these, that organization page is shadowed.
  #
  # ⚠️ **Web agents, take note**: when you add a static path (`/{org}/<new name>`) to the
  # organization-scoped router, you must add it to this list as well. Because the router captures
  # `:org_slug` as a dynamic segment, the router scan in `reserved_slugs_test` that enforces
  # `reserved?/1` cannot cover this layer (it only walks the top-level segment). This is the only
  # line of defense.
  @project_reserved ~w(
    settings
    members
    usage
    projects
    use-cases
    api-keys
    overview
    new
  )

  @doc "The full list of reserved words (sorted)."
  @spec all() :: [String.t()]
  def all, do: @reserved

  @doc """
  Whether the given slug is an **organization** reserved word. Case-insensitive (format
  validation allows only lowercase, but defensively).
  """
  @spec reserved?(term()) :: boolean()
  def reserved?(slug) when is_binary(slug), do: String.downcase(slug) in @reserved
  def reserved?(_), do: false

  @doc "The full list of project slug reserved words."
  @spec all_project() :: [String.t()]
  def all_project, do: @project_reserved

  @doc """
  Whether the given slug is a **project** reserved word (the second segment of
  `/{org_slug}/{project_slug}`).
  """
  @spec project_reserved?(term()) :: boolean()
  def project_reserved?(slug) when is_binary(slug),
    do: String.downcase(slug) in @project_reserved

  def project_reserved?(_), do: false
end
