defmodule PromptOnWeb.OrgScopeTest do
  @moduledoc """
  Tests for `/{org_slug}/{project_slug}/...` routing and the organization resolution in
  `PromptOnWeb.LiveProjectScope`.

  Checks:

  - `/personal` is **the viewer's** personal organization (nothing of another user's leaks).
  - `personal` is a reserved segment, so it never goes through the team organization lookup
    (`get_organization_by_slug/2`).
  - Team organizations open by slug, and **non-members do not even learn whether one exists**
    (they are sent back to `/personal`).
  - Project slugs are unique **per organization**: the same slug resolves to different projects
    in two organizations.
  - The router's static paths are not swallowed by `/:org_slug` (ordering contract).
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Fixtures

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "/personal (reserved segment)" do
    test "resolves to the viewer's personal organization", %{conn: conn, user: user} do
      mine = Fixtures.project_fixture(%{user: user, slug: "mine", name: "Mine"})

      {:ok, view, _html} = live(conn, ~p"/personal")

      assert has_element?(view, "#project-card-#{mine.slug}")
      assert view |> element("#current-org") |> render() =~ "Personal"
    end

    test "another user's personal organization data is never visible", %{conn: conn, user: user} do
      Fixtures.project_fixture(%{user: user, slug: "mine"})

      stranger = Fixtures.user_fixture()
      theirs = Fixtures.project_fixture(%{user: stranger, slug: "theirs"})

      {:ok, view, _html} = live(conn, ~p"/personal")

      assert has_element?(view, "#project-card-mine")
      refute has_element?(view, "#project-card-theirs")
      refute has_element?(view, "#switch-to-theirs")

      # Nor can someone else's project be opened under my `/personal`.
      assert {:error, {:redirect, %{to: "/personal", flash: flash}}} =
               live(conn, ~p"/personal/#{theirs.slug}/use-cases")

      assert flash["error"] =~ "theirs"
    end

    test "the same URL resolves to a different organization per user", %{conn: conn, user: user} do
      Fixtures.project_fixture(%{user: user, slug: "mine"})

      stranger = Fixtures.user_fixture()
      Fixtures.project_fixture(%{user: stranger, slug: "theirs"})

      {:ok, view, _html} = live(conn, ~p"/personal")
      assert has_element?(view, "#project-card-mine")

      {:ok, other_view, _html} =
        build_conn() |> log_in_user(stranger) |> live(~p"/personal")

      assert has_element?(other_view, "#project-card-theirs")
      refute has_element?(other_view, "#project-card-mine")
    end

    test "`personal` never goes through the team organization lookup (reserved, no such slug)", %{
      conn: conn,
      user: user
    } do
      # A team organization cannot take the `personal` slug: the reserved-word validation
      # rejects it.
      assert {:error, _error} =
               Accounts.create_organization(%{name: "Nope", slug: "personal"},
                 actor: Fixtures.system_actor()
               )

      # So the slug lookup always comes back empty. Yet `/personal` still opens, because it is
      # resolved by a different path.
      assert {:ok, nil} = Accounts.get_organization_by_slug("personal", actor: user)

      assert {:ok, _view, _html} = live(conn, ~p"/personal")
    end
  end

  describe "team organization (slug)" do
    setup %{user: user} do
      org = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc", name: "Acme Inc"})
      project = Fixtures.project_fixture(%{user: user, organization: org, slug: "web"})

      %{org: org, team_project: project}
    end

    test "a member opens the organization home by slug", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/#{org.slug}")

      assert has_element?(view, "#org-home-screen")
      assert has_element?(view, "#project-card-web")
      assert view |> element("#current-org") |> render() =~ "Acme Inc"
    end

    test "a member opens project screens under the team organization", %{
      conn: conn,
      org: org,
      team_project: p
    } do
      {:ok, view, _html} = live(conn, ~p"/#{org.slug}/#{p.slug}/use-cases")

      assert has_element?(view, "#use-cases-screen")

      # Links keep the viewer's addressing: under a team organization they carry the team slug.
      assert has_element?(view, "#nav-overview[href='/#{org.slug}/#{p.slug}']")
      assert has_element?(view, "#nav-settings[href='/#{org.slug}/#{p.slug}/settings']")
      assert has_element?(view, "#org-projects[href='/#{org.slug}']")
      assert has_element?(view, "#switch-org-#{org.slug}.is-current")
    end

    test "a non-member is sent back to /personal (existence is not leaked)", %{
      org: org,
      team_project: p
    } do
      outsider = Fixtures.user_fixture()
      conn = build_conn() |> log_in_user(outsider)

      assert {:error, {:redirect, %{to: "/personal", flash: flash}}} =
               live(conn, ~p"/#{org.slug}")

      assert flash["error"] =~ org.slug

      assert {:error, {:redirect, %{to: "/personal"}}} =
               live(conn, ~p"/#{org.slug}/#{p.slug}/use-cases")
    end

    test "an unknown organization slug is also sent back to /personal", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/personal", flash: flash}}} =
               live(conn, ~p"/no-such-org")

      assert flash["error"] =~ "no-such-org"
    end

    test "when signed out, organization paths also go to /sign-in", %{org: org} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/#{org.slug}")
    end
  end

  describe "project slugs are unique per organization" do
    test "same-slug projects in two organizations resolve independently", %{
      conn: conn,
      user: user
    } do
      personal_app = Fixtures.project_fixture(%{user: user, slug: "app", name: "Personal App"})

      org = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc"})

      team_app =
        Fixtures.project_fixture(%{user: user, organization: org, slug: "app", name: "Team App"})

      refute personal_app.id == team_app.id

      Fixtures.use_case_fixture(personal_app, %{key: "personal_only"})
      Fixtures.use_case_fixture(team_app, %{key: "team_only"})

      {:ok, personal_view, _html} = live(conn, ~p"/personal/app/use-cases")
      assert has_element?(personal_view, "#use-case-personal_only")
      refute has_element?(personal_view, "#use-case-team_only")

      {:ok, team_view, _html} = live(conn, ~p"/#{org.slug}/app/use-cases")
      assert has_element?(team_view, "#use-case-team_only")
      refute has_element?(team_view, "#use-case-personal_only")
    end

    test "the switcher holds only the current organization's projects", %{conn: conn, user: user} do
      Fixtures.project_fixture(%{user: user, slug: "solo"})

      org = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc"})
      Fixtures.project_fixture(%{user: user, organization: org, slug: "teamed"})

      {:ok, view, _html} = live(conn, ~p"/personal")
      assert has_element?(view, "#switch-to-solo")
      refute has_element?(view, "#switch-to-teamed")

      {:ok, view, _html} = live(conn, ~p"/#{org.slug}")
      assert has_element?(view, "#switch-to-teamed")
      refute has_element?(view, "#switch-to-solo")
    end
  end

  # The router's ordering contract: static paths come before `/:org_slug` (see the comment in
  # `PromptOnWeb.Router`).
  describe "static paths come before the organization scope" do
    test "/health is not swallowed by the organization home", %{conn: conn} do
      assert conn |> get(~p"/health") |> json_response(200)
    end

    test "/sign-in is not swallowed by the organization home", %{conn: _conn} do
      # The sign-in screen is a controller route: had `/:org_slug` come first, this would bounce
      # to `/personal`.
      html = build_conn() |> get(~p"/sign-in") |> html_response(200)

      assert html =~ "Send code"
      refute html =~ "org-home-screen"
    end

    # The second segment inside the organization scope follows the same contract:
    # `/:org_slug/settings` must sit **above** `/:org_slug/:project_slug`, or organization
    # settings get swallowed as a project.
    test "/{org}/settings|members|usage are not swallowed as project paths", %{
      conn: conn,
      user: user
    } do
      Fixtures.project_fixture(%{user: user, slug: "acme"})

      {:ok, view, _html} = live(conn, ~p"/personal/settings")
      assert has_element?(view, "#org-settings-screen")

      {:ok, view, _html} = live(conn, ~p"/personal/members")
      assert has_element?(view, "#org-members-screen")

      {:ok, view, _html} = live(conn, ~p"/personal/usage")
      assert has_element?(view, "#org-usage-screen")

      # Project screens stay project screens, the root (overview) included.
      {:ok, view, _html} = live(conn, ~p"/personal/acme")
      assert has_element?(view, "#project-overview-screen")

      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings")
      assert has_element?(view, "#settings-screen")

      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys")
      assert has_element?(view, "#api-keys-screen")
    end

    # Using those names as project slugs would shadow the organization screens; the domain
    # blocks it.
    test "reserved project slugs cannot be created", %{conn: conn} do
      for reserved <- ~w(settings members usage api-keys overview) do
        {:ok, view, _html} = live(conn, ~p"/personal?new=1")

        view
        |> form("#new-project-form", form: %{"name" => "X", "slug" => reserved})
        |> render_submit()

        assert has_element?(view, "#new-project-modal"), "expected #{reserved} to be rejected"
      end
    end

    test "/account is not swallowed by the organization home", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account")

      assert has_element?(view, "#account-screen")
    end

    test "the reserved-word list covers every static top-level route in the router", %{
      conn: _conn
    } do
      # The detailed enforcement lives in `PromptOn.Accounts.ReservedSlugsTest`; here we only
      # double-check that no new route slipped past the reserved words.
      top =
        PromptOnWeb.Router.__routes__()
        |> Enum.map(&(&1.path |> String.split("/", trim: true) |> List.first()))
        |> Enum.reject(&(is_nil(&1) or String.starts_with?(&1, ":")))
        |> Enum.uniq()

      assert Enum.all?(top, &PromptOn.Accounts.ReservedSlugs.reserved?/1)
    end
  end
end
