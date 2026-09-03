defmodule PromptOnWeb.OrgHomeLiveTest do
  @moduledoc """
  Organization home = that organization's project list (`/:org_slug`, mockup `s_overview.jsx`)
  tests.

  Checks: cards carry the real use case count and environment slugs, the `?new=1` modal is URL
  state, creation navigates to the new project, and **both the list and creation are confined to
  the organization being viewed** (`/personal` is my personal organization, `/{team}` is that
  team organization).
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Fixtures
  alias PromptOn.Projects

  doctest PromptOnWeb.OrgHomeLive, import: true
  doctest PromptOnWeb.SettingsComponents, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})

    %{conn: log_in_user(conn, user), user: user, project: project}
  end

  describe "cards" do
    test "a project card shows the use case count and environment slugs", %{
      conn: conn,
      project: project
    } do
      Fixtures.use_case_fixture(project, %{key: "diary_generation"})
      Fixtures.use_case_fixture(project, %{key: "chat_response"})

      {:ok, view, _html} = live(conn, ~p"/personal")

      card = view |> element("#project-card-acme") |> render()

      assert card =~ "acme"
      assert card =~ "Acme"
      assert card =~ "2"
      assert card =~ "production"
      assert card =~ "staging"
    end

    test "the sidebar switcher and the card use the same color for the same project", %{
      conn: conn,
      project: project
    } do
      # The mockups (`sidebar.jsx`, `s_overview.jsx`) give each project one color. Keeping two
      # palettes would make the sidebar tile and the card tile disagree on the same screen.
      {:ok, view, _html} = live(conn, ~p"/personal")

      color = PromptOnWeb.DS.project_color(project.slug)

      assert view |> element("#switch-to-acme") |> render() =~ color
      assert view |> element("#project-card-acme") |> render() =~ color
    end

    test "a project switcher row shows the use case count (mockup `{n} uc`)", %{
      conn: conn,
      project: project
    } do
      Fixtures.use_case_fixture(project, %{key: "diary_generation"})
      Fixtures.use_case_fixture(project, %{key: "chat_response"})

      {:ok, view, _html} = live(conn, ~p"/personal")
      assert view |> element("#switch-to-acme") |> render() =~ "2 uc"

      {:ok, view, _html} = live(conn, ~p"/personal/acme/use-cases")
      assert view |> element("#switch-to-acme") |> render() =~ "2 uc"
    end

    test "the card goes to the use case list and the ⋯ goes to settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal")

      assert has_element?(view, "#open-project-acme[href='/personal/acme/use-cases']")
      assert has_element?(view, "#manage-project-acme[href='/personal/acme/settings']")
    end

    test "another user's projects have no card", %{conn: conn} do
      stranger = Fixtures.user_fixture()
      Fixtures.project_fixture(%{user: stranger, slug: "hidden"})

      {:ok, view, _html} = live(conn, ~p"/personal")

      assert has_element?(view, "#project-card-acme")
      refute has_element?(view, "#project-card-hidden")
    end
  end

  describe "new project" do
    test "the modal stays in the URL as ?new=1", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal")

      refute has_element?(view, "#new-project-modal")

      view |> element("#new-project-btn") |> render_click()

      assert_patched(view, ~p"/personal?new=1")
      assert has_element?(view, "#new-project-modal")
    end

    test "can be opened directly from the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal?new=1")

      assert has_element?(view, "#new-project-form")
    end

    test "the slug is suggested from the name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal?new=1")

      html =
        view
        |> form("#new-project-form", form: %{"name" => "Note Mesh!", "slug" => ""})
        |> render_change()

      assert html =~ "note-mesh"
    end

    test "creating navigates to the new project's use case list", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/personal?new=1")

      view
      |> form("#new-project-form", form: %{"name" => "Note Mesh", "slug" => "notemesh"})
      |> render_submit()

      assert_redirect(view, ~p"/personal/notemesh/use-cases")

      {:ok, projects} = Projects.list_projects(actor: user)
      created = Enum.find(projects, &(&1.slug == "notemesh"))

      assert created.name == "Note Mesh"
      # Context dimensions were deleted (ADR 0007 revision 2026-09-01: deployments are pins).
      refute Map.has_key?(created, :dimensions)

      # The default environments are created alongside.
      {:ok, envs} = Projects.list_environments(tenant: created.id, actor: user)
      assert Enum.map(envs, & &1.slug) |> Enum.sort() == ["production", "staging"]
    end

    test "a duplicate slug stays as a form error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal?new=1")

      html =
        view
        |> form("#new-project-form", form: %{"name" => "Acme 2", "slug" => "acme"})
        |> render_submit()

      assert has_element?(view, "#new-project-modal")
      assert html =~ "already been taken" or html =~ "acme"
    end
  end

  describe "organization scope" do
    test "a team organization's home holds only that organization's projects", %{
      conn: conn,
      user: user
    } do
      org = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc", name: "Acme Inc"})
      Fixtures.project_fixture(%{user: user, organization: org, slug: "web", name: "Web"})

      {:ok, view, _html} = live(conn, ~p"/#{org.slug}")

      assert has_element?(view, "#project-card-web")
      # The personal organization's `acme` is not here: the list is confined to the organization.
      refute has_element?(view, "#project-card-acme")
      assert view |> element("#org-home-screen") |> render() =~ "Acme Inc"
    end

    test "a new project goes into **the organization being viewed**", %{conn: conn, user: user} do
      org = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc"})

      {:ok, view, _html} = live(conn, ~p"/#{org.slug}?new=1")

      view
      |> form("#new-project-form", form: %{"name" => "Web", "slug" => "web"})
      |> render_submit()

      assert_redirect(view, ~p"/#{org.slug}/web/use-cases")

      {:ok, created} = Projects.get_project_by_slug(org.id, "web", actor: user)
      assert created.organization_id == org.id
    end

    test "can be created even if another organization has the same slug (unique per org)", %{
      conn: conn,
      user: user
    } do
      org = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc"})

      {:ok, view, _html} = live(conn, ~p"/#{org.slug}?new=1")

      view
      |> form("#new-project-form", form: %{"name" => "Acme", "slug" => "acme"})
      |> render_submit()

      assert_redirect(view, ~p"/#{org.slug}/acme/use-cases")

      {:ok, %{} = team_acme} = Projects.get_project_by_slug(org.id, "acme", actor: user)
      personal = Fixtures.organization_for(user)
      {:ok, %{} = personal_acme} = Projects.get_project_by_slug(personal.id, "acme", actor: user)

      refute team_acme.id == personal_acme.id
    end
  end

  describe "provider setup card" do
    test "with no key the card shows up and registers an organization key in place", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal")

      assert has_element?(view, "#provider-setup-card")
      html = render(view)
      assert html =~ "Connect OpenRouter"
      assert html =~ "More providers later"
      # The provider is fixed: there is nothing to pick.
      refute has_element?(view, "#setup-provider")

      view
      |> form("#provider-setup-form",
        provider_key: %{"secret" => "sk-or-v1-0123456789abcdefWxYz"}
      )
      |> render_submit()

      # The card goes away and the key stays owned by the **organization**.
      refute has_element?(view, "#provider-setup-card")

      org = Fixtures.organization_for(user)
      assert {:ok, [key]} = Accounts.list_provider_keys(org.id, actor: user)
      assert key.provider == :openrouter
      assert key.organization_id == org.id
      # The raw secret is nowhere on the screen.
      refute render(view) =~ "0123456789abcdef"
    end

    test "Do this later folds the card for this session only (nothing is saved)", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal")

      view |> element("#setup-later") |> render_click()
      refute has_element?(view, "#provider-setup-card")

      # There is no saved dismissal: coming back, the card is still there.
      {:ok, view, _html} = live(conn, ~p"/personal")
      assert has_element?(view, "#provider-setup-card")

      # And no key was created.
      org = Fixtures.organization_for(user)
      assert {:ok, []} = Accounts.list_provider_keys(org.id, actor: user)
    end

    test "the card does not show when a key already exists", %{conn: conn, user: user} do
      Fixtures.provider_key_fixture(Fixtures.organization_for(user))

      {:ok, view, _html} = live(conn, ~p"/personal")

      refute has_element?(view, "#provider-setup-card")
    end

    test "shows the same way on a freshly created team organization", %{conn: conn, user: user} do
      org = Fixtures.team_org_fixture(%{user: user, slug: "fresh-co"})

      {:ok, view, _html} = live(conn, ~p"/#{org.slug}")

      assert has_element?(view, "#provider-setup-card")
      assert has_element?(view, "#setup-settings-link[href='/fresh-co/settings?tab=providers']")
    end
  end

  describe "new organization" do
    test "the modal stays in the URL as ?new_org=1", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal")

      refute has_element?(view, "#new-org-modal")

      view |> element("#new-org-btn") |> render_click()

      assert_patched(view, ~p"/personal?new_org=1")
      assert has_element?(view, "#new-org-form")
    end

    test "creating goes to the new organization's home and the creator is the owner", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal?new_org=1")

      view
      |> form("#new-org-form", organization: %{"name" => "Note Mesh", "slug" => ""})
      |> render_submit()

      assert_redirect(view, ~p"/note-mesh")

      assert {:ok, %{} = org} = Accounts.get_organization_by_slug("note-mesh", actor: user)
      refute org.personal?

      assert {:ok, [%{role: :owner, user_id: owner_id}]} =
               Accounts.list_memberships(
                 actor: user,
                 query: [filter: [organization_id: org.id]]
               )

      assert owner_id == user.id
    end

    test "a reserved word or duplicate slug stays in the modal", %{conn: conn, user: user} do
      Fixtures.team_org_fixture(%{user: user, slug: "taken-co"})

      for bad <- ["settings", "taken-co"] do
        {:ok, view, _html} = live(conn, ~p"/personal?new_org=1")

        html =
          view
          |> form("#new-org-form", organization: %{"name" => "X", "slug" => bad})
          |> render_submit()

        assert html =~ "flash-error", "expected #{bad} to be rejected"
        assert has_element?(view, "#new-org-form")
      end
    end
  end

  describe "access control" do
    test "redirects to /sign-in when signed out" do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/personal")
    end
  end
end
