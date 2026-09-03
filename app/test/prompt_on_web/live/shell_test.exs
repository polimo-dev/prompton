defmodule PromptOnWeb.ShellTest do
  @moduledoc """
  App shell (sidebar + `DS.screen`) and routing wiring tests.

  The sidebar draws the hierarchy as it is (2026-09-01 restructure, `PromptOnWeb.Layouts`
  moduledoc): **top = the current organization** (`#org-menu` popup + organization switching),
  **middle = the project** (switcher + the four screens), **bottom = the account** (`#user-menu`
  popup). The collapse toggle is the small icon on the right of the organization row.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Fixtures

  doctest PromptOnWeb.Layouts, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})
    other = Fixtures.project_fixture(%{user: user, slug: "zeta", name: "Zeta"})
    use_case = Fixtures.use_case_fixture(project, %{key: "diary_generation"})

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      other: other,
      use_case: use_case
    }
  end

  # Project screens: the four sidebar nav items plus the use case hub.
  defp project_paths(project, use_case) do
    [
      {"overview", ~p"/personal/#{project.slug}", "#project-overview-screen"},
      {"use-cases", ~p"/personal/#{project.slug}/use-cases", "#use-cases-screen"},
      {"use case hub", ~p"/personal/#{project.slug}/use-cases/#{use_case.key}/prompt",
       "#use-case-hub"},
      {"api keys", ~p"/personal/#{project.slug}/api-keys", "#api-keys-screen"},
      {"settings", ~p"/personal/#{project.slug}/settings", "#settings-screen"}
    ]
  end

  # Folded screens: there must be no route at all (the use case hub absorbed them).
  defp folded_paths(project) do
    [
      "/personal/#{project.slug}/playground",
      "/personal/#{project.slug}/models",
      "/personal/#{project.slug}/deployments"
    ]
  end

  describe "authentication" do
    test "when signed out every screen goes to /sign-in", %{project: project, use_case: uc} do
      conn = build_conn()

      paths =
        [{"org home", ~p"/personal", nil} | project_paths(project, uc)] ++
          [{"use case", ~p"/personal/#{project.slug}/use-cases/#{uc.key}", nil}]

      for {_name, path, _selector} <- paths do
        assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, path)
      end
    end
  end

  describe "shell" do
    test "/personal (organization home) renders with the sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal")

      assert has_element?(view, "#sidebar")
      assert has_element?(view, "#org-home-screen")
      assert has_element?(view, "#org-projects.is-current")
      assert has_element?(view, "#project-cards")
    end

    test "every project screen has the sidebar and its screen", %{
      conn: conn,
      project: project,
      use_case: uc
    } do
      for {name, path, selector} <- project_paths(project, uc) do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "#sidebar"), "#{name}: no sidebar"
        assert has_element?(view, selector), "#{name}: no #{selector}"
        assert has_element?(view, "#org-menu"), "#{name}: no organization menu"
        assert has_element?(view, "#project-switcher"), "#{name}: no project switcher"
        assert has_element?(view, "#user-menu"), "#{name}: no user menu"
      end
    end

    test "the old paths of folded screens have no route", %{conn: conn, project: project} do
      for path <- folded_paths(project) do
        assert get(conn, path).status == 404, "#{path}: still has a route"
      end
    end

    # The self-hosted card went away on 2026-09-01: the sidebar draws only the hierarchy
    # (organization, project, account). Operational numbers (Oban backlog, snapshot etag) never
    # belonged in the sidebar, and their assigns were removed along with it.
    test "the sidebar has no self-hosted card", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      refute html =~ "Self-hosted"
      refute has_element?(view, "#self-host-queue")
      refute has_element?(view, "#self-host-etag")
    end

    test "the screen crumb runs organization → project", %{
      conn: conn,
      project: project,
      use_case: uc
    } do
      for path <- [
            ~p"/personal/#{project.slug}/use-cases",
            ~p"/personal/#{project.slug}/use-cases/#{uc.key}/prompt",
            ~p"/personal/#{project.slug}/settings"
          ] do
        {:ok, view, _html} = live(conn, path)
        html = render(view)

        assert html =~ "Personal", "#{path}: no organization crumb"
        assert has_element?(view, "a[href='/personal']"), "#{path}: no organization home link"
        assert html =~ project.slug, "#{path}: no project crumb"
      end
    end
  end

  # Top = the current organization. This is where the brand block used to be.
  describe "sidebar: organization head" do
    test "shows the current organization (the personal organization is Personal)", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal")
      assert view |> element("#current-org") |> render() =~ "Personal"

      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")
      assert view |> element("#current-org") |> render() =~ "Personal"
    end

    test "the PromptOn brand block is gone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal")

      refute has_element?(view, ".sidebar-brand")
      # The app name and version moved down into the account popup.
      assert has_element?(view, "#user-menu #app-version")
    end

    test "the organization menu holds the four organization screens", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert has_element?(view, "#org-projects[href='/personal']")
      assert has_element?(view, "#org-members[href='/personal/members']")
      assert has_element?(view, "#org-usage[href='/personal/usage']")
      assert has_element?(view, "#org-settings[href='/personal/settings']")
      assert has_element?(view, "#new-organization")
    end

    test "on an organization screen that item is marked current", %{conn: conn} do
      for {path, selector} <- [
            {~p"/personal/members", "#org-members"},
            {~p"/personal/usage", "#org-usage"},
            {~p"/personal/settings", "#org-settings"}
          ] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "#{selector}.is-current"), "#{path}: #{selector} is not current"
      end
    end

    test "the switch list holds all of the user's organizations, personal first", %{
      conn: conn,
      user: user
    } do
      team = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc", name: "Acme Inc"})

      {:ok, view, _html} = live(conn, ~p"/personal")

      assert has_element?(view, "#switch-org-personal.is-current[href='/personal']")
      assert has_element?(view, "#switch-org-#{team.slug}[href='/#{team.slug}']")
      refute has_element?(view, "#switch-org-#{team.slug}.is-current")

      menu = view |> element("#org-menu") |> render()
      assert menu =~ "Switch organization"

      personal_at = :binary.match(menu, "switch-org-personal") |> elem(0)
      team_at = :binary.match(menu, "switch-org-#{team.slug}") |> elem(0)
      assert personal_at < team_at, "the personal organization must come first in the list"

      # Viewing a team organization flips the current markers.
      {:ok, view, _html} = live(conn, ~p"/#{team.slug}")
      assert has_element?(view, "#switch-org-#{team.slug}.is-current")
      refute has_element?(view, "#switch-org-personal.is-current")
    end

    test "other users' organizations are not in the switch list", %{conn: conn} do
      stranger = Fixtures.user_fixture()
      theirs = Fixtures.team_org_fixture(%{user: stranger, slug: "not-mine"})

      {:ok, view, _html} = live(conn, ~p"/personal")

      refute has_element?(view, "#switch-org-#{theirs.slug}")
    end

    test "New organization goes to the creation modal on the organization home", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert has_element?(view, "#new-organization[href='/personal?new_org=1']")

      {:ok, view, _html} = live(conn, ~p"/personal?new_org=1")
      assert has_element?(view, "#new-org-modal")
    end
  end

  # Middle = the project.
  describe "sidebar: project" do
    test "the nav is the four items Overview, Use cases, API keys, Settings", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert has_element?(view, "#nav-overview[href='/personal/#{project.slug}']")
      assert has_element?(view, "#nav-usecases[href='/personal/#{project.slug}/use-cases']")
      assert has_element?(view, "#nav-apikeys[href='/personal/#{project.slug}/api-keys']")
      assert has_element?(view, "#nav-settings[href='/personal/#{project.slug}/settings']")

      # Projects moved up into the organization menu; Playground, Models and Deployments live
      # inside the hub.
      refute has_element?(view, "#nav-projects")
      refute has_element?(view, "#nav-playground")
      refute has_element?(view, "#nav-models")
      refute has_element?(view, "#nav-deployments")
    end

    test "with no project (organization home) there is no project nav either", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal")

      refute has_element?(view, "#nav-overview")
      refute has_element?(view, "#nav-usecases")
    end

    test "the active nav item differs per screen", %{conn: conn, project: project, use_case: uc} do
      expected = [
        {~p"/personal/#{project.slug}", "#nav-overview"},
        {~p"/personal/#{project.slug}/use-cases", "#nav-usecases"},
        {~p"/personal/#{project.slug}/use-cases/#{uc.key}/prompt", "#nav-usecases"},
        {~p"/personal/#{project.slug}/api-keys", "#nav-apikeys"},
        {~p"/personal/#{project.slug}/settings", "#nav-settings"}
      ]

      for {path, selector} <- expected do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "#{selector}.active"), "#{path}: #{selector} is not active"
      end
    end

    test "the project switcher holds all of the user's projects", %{
      conn: conn,
      project: project,
      other: other
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert has_element?(view, "#switch-to-#{project.slug}.is-current")
      assert has_element?(view, "#switch-to-#{other.slug}")
      refute has_element?(view, "#switch-to-#{other.slug}.is-current")
    end
  end

  # Bottom = the account.
  describe "sidebar: account" do
    test "the user menu holds account settings and sign out", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert view |> element("#current-user") |> render() =~ to_string(user.email)
      assert has_element?(view, "#account-settings[href='/account']")
      assert has_element?(view, "#sign-out[href='/sign-out']")
    end

    test "on /account the account item is marked current", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account")

      assert has_element?(view, "#account-settings.is-current")
    end
  end

  # Collapsing itself is a client chrome preference, not LiveView state (localStorage + a class
  # on `<html>`). The server is responsible only for **the toggle with its hook** and **markup
  # that CSS can collapse**, so that is as far as the tests go.
  describe "sidebar collapse" do
    test "the toggle is an icon button inside the organization row with a colocated hook", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert has_element?(view, "#sidebar.sidebar")
      assert has_element?(view, ".sidebar-org > #sidebar-toggle")
      assert has_element?(view, "#sidebar-toggle[phx-hook='PromptOnWeb.Layouts.SidebarToggle']")
      assert has_element?(view, "#sidebar-toggle[aria-controls='sidebar']")

      # Only the icon remains: it has to sit in the same spot on the rail, so it carries no
      # label.
      refute has_element?(view, "#sidebar-toggle .sidebar-label")

      # The server does not know the saved state: it renders the expanded default and the hook
      # rewrites it on mount.
      assert has_element?(view, "#sidebar-toggle[aria-expanded='true'][title='Collapse sidebar']")
    end

    test "the things that must hide when collapsed carry the CSS hook class", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      # Labels (text that disappears, leaving only the icon or mark)
      assert has_element?(view, "#org-menu .sidebar-label")
      assert has_element?(view, "#nav-overview .sidebar-label")
      assert has_element?(view, "#nav-usecases .sidebar-label")
      assert has_element?(view, "#nav-apikeys .sidebar-label")
      assert has_element?(view, "#nav-settings .sidebar-label")
      assert has_element?(view, "#project-switcher .sidebar-label")
      assert has_element?(view, "#user-menu .sidebar-label")

      # Expanded-only blocks (the project nav's vertical line, the chevron on the account row)
      assert has_element?(view, "#sidebar .sidebar-full")
    end

    test "titles are attached so items are recognizable on the icon rail too", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      # What stays on the rail: organization mark, toggle, project mark, nav icons, avatar.
      assert has_element?(view, "#org-menu summary[title='Personal']")
      assert has_element?(view, "#sidebar-toggle[title='Collapse sidebar']")
      assert has_element?(view, "#project-switcher summary[title='#{project.slug}']")
      assert has_element?(view, "#nav-overview[title='Overview']")
      assert has_element?(view, "#nav-usecases[title='Use cases']")
      assert has_element?(view, "#nav-apikeys[title='API keys']")
      assert has_element?(view, "#nav-settings[title='Settings']")
      assert has_element?(view, "#user-menu summary[title]")
    end

    test "the root layout restores the saved state before first paint", %{
      conn: conn,
      project: project
    } do
      html = conn |> get(~p"/personal/#{project.slug}/use-cases") |> html_response(200)

      assert html =~ "pon:sidebar"
      assert html =~ "sidebar-collapsed"
    end

    test "the toggle is still there after a remount (LiveView navigation)", %{
      conn: conn,
      project: project,
      other: other
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      view
      |> element("#switch-to-#{other.slug}")
      |> render_click()

      {:ok, view, _html} = live(conn, ~p"/personal/#{other.slug}/use-cases")

      assert has_element?(view, "#sidebar-toggle[phx-hook='PromptOnWeb.Layouts.SidebarToggle']")
      assert has_element?(view, "#nav-usecases .sidebar-label")
    end
  end

  describe "project scope" do
    test "an unknown slug is sent back to /personal", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/personal", flash: flash}}} =
               live(conn, ~p"/personal/nope/use-cases")

      assert flash["error"] =~ "nope"
    end

    test "another user's project is not visible", %{conn: conn} do
      stranger = Fixtures.user_fixture()
      hidden = Fixtures.project_fixture(%{user: stranger, slug: "hidden"})

      assert {:error, {:redirect, %{to: "/personal"}}} =
               live(conn, ~p"/personal/#{hidden.slug}/use-cases")
    end

    test "an unknown use case key is sent back to the list", %{conn: conn, project: project} do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/personal/#{project.slug}/use-cases/nope")

      assert to == "/personal/#{project.slug}/use-cases"
      assert flash["error"] =~ "nope"
    end
  end

  describe "URL state (zero-downtime deployment discipline)" do
    test "the overview period is a patch link and stays in the URL", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}")

      view |> element("#overview-period a", "7d") |> render_click()

      assert_patched(view, ~p"/personal/#{project.slug}?period=7d")
      assert view |> element("#overview-period a.on") |> render() =~ "7d"
    end

    test "the key issue modal is a patch and opens directly from the URL", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/api-keys")

      view |> element("#issue-key") |> render_click()
      assert_patched(view, ~p"/personal/#{project.slug}/api-keys?issue=1")

      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/api-keys?issue=1")
      assert has_element?(view, "#issue-key-modal")
    end

    test "use case hub tabs are patches too", %{conn: conn, project: project, use_case: uc} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases/#{uc.key}/prompt")

      assert has_element?(view, "#tab-editor.is-active")

      view
      |> element("#tab-deployments")
      |> render_click()

      assert_patched(
        view,
        ~p"/personal/#{project.slug}/use-cases/#{uc.key}/prompt?#{[tab: "deployments"]}"
      )

      assert has_element?(view, "#tab-deployments.is-active")
    end

    test "the old use case detail path is sent to the hub", %{
      conn: conn,
      project: project,
      use_case: uc
    } do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/personal/#{project.slug}/use-cases/#{uc.key}")

      assert to == "/personal/#{project.slug}/use-cases/#{uc.key}/prompt"
    end
  end
end
